import Foundation
import ARKit
import simd

/// 哈佛 Mobilio 障碍系统的 Swift 移植（MIT 协议）。
/// 论文《Improving navigation for people with blindness using an AI-driven smartphone
/// application and personalized audio guidance》(Nature BME)；
/// 源码 github.com/Harvard-Slade-Lab/Mobilio → scripts/DepthImage.cs。
///
/// 思路：LiDAR 深度 + ARKit 位姿 → 10cm 体素栅格世界模型（视野内衰减=路过的行人自动消失）
/// → 动态地面估计（不把地面当障碍）→ 人体走廊判定（前方1.5m×肩宽）
/// → 受阻时在 2D 搜索网格上扇形扫描射线找绕行方向。
final class Rover {
    // 参数沿用 Mobilio 实测值
    static let nodeSize: Float = 0.1
    static let searchRadius: Float = 4
    static let distanceToObstacle: Float = 1.5     // 走廊长度：报警距离
    static let paddedDistance: Float = 2           // 找绕行方向时的探测距离
    static let personRadius: Float = 0.25          // 半肩宽
    static let personHeight: Float = 1.7
    static let pointsToBlockCell: Float = 3        // 体素被判"占据"所需点数（2→3：用户反馈太敏感）
    static let cellsToBlockPerson = 3              // 走廊内≥3个占据体素=挡路（2→3：同上）
    static let groundPadding: Float = 0.4
    static let groundRadius: Float = 0.3
    static let cellDeletionRange: Float = searchRadius + 1

    private static let searchWidthHalf = Int(searchRadius / nodeSize)      // 40
    private static let searchWidth = 1 + 2 * searchWidthHalf               // 81

    struct Output {
        let closest: Float       // 走廊内最近障碍（米；999=走廊干净）
        let blocked: Bool        // 走廊是否被挡
        let detourDeg: Float     // 绕行方向（度，右正左负；未挡=0）
    }

    private var grid = [SIMD3<Int32>: Float]()     // 体素 → 累计点数
    private var ground: Float = -1.4               // 地面相对相机高度（胸前佩戴约-1.3~-1.5）
    private var searchGrid = [UInt8](repeating: 0, count: searchWidth * searchWidth)
    private static let circleCells: [(Int, Int)] = {   // personRadius 的占位圆
        var c: [(Int, Int)] = []
        let bound = Int(ceil(personRadius / nodeSize))
        for i in -bound...bound {
            for j in -bound...bound where !(i == 0 && j == 0) {
                if (Float(i * i + j * j)).squareRoot() <= personRadius / nodeSize { c.append((i, j)) }
            }
        }
        return c
    }()

    // 相机状态（每帧更新）
    private var position = SIMD3<Float>(0, 0, 0)
    private var fwd = SIMD3<Float>(0, 0, -1)       // 水平朝向（世界系）
    private var rightV = SIMD3<Float>(1, 0, 0)

    // MARK: - 主入口：喂一帧（调用方控制节奏，建议 5~8Hz）

    func ingest(_ frame: ARFrame) -> Output? {
        guard let depth = frame.sceneDepth else { return nil }
        let t = frame.camera.transform
        position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // 水平朝向：相机 -Z 投到水平面；手机朝下看时退化，保持上一帧朝向
        let f = SIMD3(-t.columns.2.x, Float(0), -t.columns.2.z)
        if simd_length(f) > 0.3 { fwd = simd_normalize(f) }
        let r = SIMD3(t.columns.0.x, Float(0), t.columns.0.z)
        if simd_length(r) > 0.3 { rightV = simd_normalize(r) }

        processDepth(frame: frame, depth: depth)
        cullAndDecay(frame: frame)
        return checkForObstacle()
    }

    func reset() {
        grid.removeAll()
        ground = -1.4
    }

    // MARK: - 真机自检：合成场景验证走廊判定与绕行方向的左右正确性（防移植镜像 bug）

    func syntheticCheck() -> String {
        func scenario(wallCoversLeft: Bool) -> (blocked: Bool, detour: Float) {
            grid.removeAll(); ground = -1.4
            position = .zero
            fwd = SIMD3(0, 0, -1)       // 朝 -Z 看（ARKit 相机惯例）
            rightV = SIMD3(1, 0, 0)
            // 1 米外一堵墙：盖住走廊（含正中列）并向一侧延伸，另一侧敞开。
            // 点必须放格子中心（0.1 整数倍）：放在半格边界上会落在舍入临界点，结果成噪声。
            let ixRange = wallCoversLeft ? (-12)...1 : (-1)...12
            for ix in ixRange {
                for iy in -10...3 {
                    let x = Float(ix) * 0.1, y = Float(iy) * 0.1
                    for _ in 0..<5 {    // 必须 > pointsToBlockCell
                        addToGrid(SIMD3(x, y, -1.0))
                        addToGrid(SIMD3(x, y, -1.1))
                    }
                }
            }
            let out = checkForObstacle()
            return (out.blocked, out.detourDeg)
        }
        let a = scenario(wallCoversLeft: true)    // 墙占中+左 → 应判挡 & 往右绕(+)
        let b = scenario(wallCoversLeft: false)   // 墙占中+右 → 应判挡 & 往左绕(−)
        grid.removeAll(); ground = -1.4
        let clear = checkForObstacle()
        let s1 = a.blocked ? "✓" : "✗"
        let s2 = (a.blocked && a.detour > 0) ? "✓" : "✗"
        let s3 = (b.blocked && b.detour < 0) ? "✓" : "✗"
        let s4 = !clear.blocked ? "✓" : "✗"
        grid.removeAll()
        return "挡墙\(s1) 右绕\(s2)(\(Int(a.detour))°) 左绕\(s3)(\(Int(b.detour))°) 空场通畅\(s4)"
    }

    // MARK: - 深度 → 体素

    private func processDepth(frame: ARFrame, depth: ARDepthData) {
        let map = depth.depthMap
        guard let confMap = depth.confidenceMap else { return }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(confMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            CVPixelBufferUnlockBaseAddress(confMap, .readOnly)
        }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard let dBase = CVPixelBufferGetBaseAddress(map),
              let cBase = CVPixelBufferGetBaseAddress(confMap) else { return }
        let dRow = CVPixelBufferGetBytesPerRow(map) / 4
        let cRow = CVPixelBufferGetBytesPerRow(confMap)
        let dPtr = dBase.assumingMemoryBound(to: Float32.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)

        // 相机内参按深度图分辨率缩放
        let intr = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let fx = intr[0][0] * sx, fy = intr[1][1] * sy
        let cx = intr[2][0] * sx, cy = intr[2][1] * sy
        let t = frame.camera.transform

        let stride = 2   // 128×96 采样，5~8Hz 下 CPU 无压力
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let conf = cPtr[y * cRow + x]
                if conf >= 1 {   // medium 以上（对应 Mobilio 的 0.51 阈值）
                    let z = dPtr[y * dRow + x]
                    if z > 0.1, z < Rover.searchRadius {
                        // 像素→相机系（ARKit：+X右 +Y上 -Z前；像素v向下）→世界系
                        let lx = (Float(x) - cx) * z / fx
                        let ly = -(Float(y) - cy) * z / fy
                        let local = SIMD4<Float>(lx, ly, -z, 1)
                        let wpt = t * local
                        addToGrid(SIMD3(wpt.x, wpt.y, wpt.z))
                    }
                }
                x += stride
            }
            y += stride
        }
    }

    private func addToGrid(_ v: SIMD3<Float>) {
        let n = Rover.nodeSize
        let cell = SIMD3<Int32>(Int32((v.x / n).rounded()), Int32((v.y / n).rounded()), Int32((v.z / n).rounded()))
        grid[cell, default: 0] += 1
    }

    // MARK: - 视锥剔除 + 衰减（动态物体离开后自动消失的关键）

    private struct Plane {
        var n: SIMD3<Float>; var p: SIMD3<Float>
        func side(_ v: SIMD3<Float>) -> Bool { simd_dot(n, v - p) > 0 }
    }

    private func cullAndDecay(frame: ARFrame) {
        // 四角在 z=1 处的世界坐标 → 过相机位置的四个侧面
        let map = frame.sceneDepth?.depthMap
        let w = map.map { Float(CVPixelBufferGetWidth($0)) } ?? 256
        let h = map.map { Float(CVPixelBufferGetHeight($0)) } ?? 192
        let intr = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let sx = w / Float(res.width), sy = h / Float(res.height)
        let fx = intr[0][0] * sx, fy = intr[1][1] * sy
        let cx = intr[2][0] * sx, cy = intr[2][1] * sy
        let t = frame.camera.transform
        func corner(_ px: Float, _ py: Float) -> SIMD3<Float> {
            let local = SIMD4<Float>((px - cx) / fx, -(py - cy) / fy, -1, 1)
            let wp = t * local
            return SIMD3(wp.x, wp.y, wp.z)
        }
        let tl = corner(0, 0), tr = corner(w - 1, 0), br = corner(w - 1, h - 1), bl = corner(0, h - 1)
        let center = corner(w / 2, h / 2)

        func plane(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Plane {
            var n = simd_normalize(simd_cross(a - position, b - position))
            if simd_dot(n, center - position) < 0 { n = -n }   // 法线统一朝视野内
            let halfDiag: Float = 0.866 * Rover.nodeSize
            return Plane(n: n, p: position + n * halfDiag)     // 内缩半格：只处理完全可见的体素
        }
        let planes = [plane(br, tr), plane(bl, br), plane(tl, bl), plane(tr, tl)]

        var toRemove: [SIMD3<Int32>] = []
        let n = Rover.nodeSize
        for (cell, count) in grid {
            let v = SIMD3(Float(cell.x) * n, Float(cell.y) * n, Float(cell.z) * n)
            let horiz = SIMD2(v.x - position.x, v.z - position.z)
            if simd_length(horiz) > Rover.cellDeletionRange {
                toRemove.append(cell)
            } else if planes.allSatisfy({ $0.side(v) }) {
                // 在视野内：没新点落进来就衰减——路过的行人走了，格子几帧内自己清掉
                let decayed = count * 0.9
                if decayed < 0.5 { toRemove.append(cell) } else { grid[cell] = decayed }
            }
        }
        for c in toRemove { grid.removeValue(forKey: c) }
    }

    // MARK: - 走廊判定 + 地面估计

    private func checkForObstacle() -> Output {
        var closest: Float = 999
        var closestSq: Float = 999 * 999
        var groundSum: Float = 0
        var groundCount: Float = 0
        var blockingPoints = 0
        let n = Rover.nodeSize
        let f2 = SIMD2(fwd.x, fwd.z), r2 = SIMD2(rightV.x, rightV.z)

        for (cell, count) in grid where count > Rover.pointsToBlockCell {
            let v = SIMD3(Float(cell.x) * n, Float(cell.y) * n, Float(cell.z) * n)
            let d = v - position
            if d.y > ground, d.y < ground + Rover.personHeight {
                let dxz = SIMD2(d.x, d.z)
                let rZ = simd_dot(dxz, f2)      // 前向距离
                let rX = simd_dot(dxz, r2)      // 侧向偏移
                if rZ > 0, rZ < Rover.distanceToObstacle, abs(rX) < Rover.personRadius {
                    blockingPoints += 1
                    let sq = rX * rX + rZ * rZ
                    if sq < closestSq { closestSq = sq }
                }
            }
            if d.y < 0, simd_length(SIMD2(d.x, d.z)) < Rover.groundRadius {
                groundSum += d.y * count
                groundCount += count
            }
        }
        closest = closestSq.squareRoot()
        if groundCount >= 3 {
            ground = min(-0.5, groundSum / groundCount + Rover.groundPadding)
        }
        let blocked = blockingPoints >= Rover.cellsToBlockPerson
        return Output(closest: closest, blocked: blocked, detourDeg: blocked ? runSearch() : 0)
    }

    // MARK: - 绕行方向搜索（2D 网格 + 扇形射线）

    private func runSearch() -> Float {
        searchGrid.replaceSubrange(0..., with: repeatElement(0, count: searchGrid.count))
        let n = Rover.nodeSize
        let half = Rover.searchWidthHalf, width = Rover.searchWidth
        let f2 = SIMD2(fwd.x, fwd.z), r2 = SIMD2(rightV.x, rightV.z)

        for (cell, count) in grid where count > Rover.pointsToBlockCell {
            let v = SIMD3(Float(cell.x) * n, Float(cell.y) * n, Float(cell.z) * n)
            let d = v - position
            guard d.y > ground, d.y < ground + Rover.personHeight else { continue }
            let dxz = SIMD2(d.x, d.z)
            // 必须四舍五入：Int() 向零截断对正负不对称，会造成左右绕行偏置（合成自检抓出来的）
            let i = Int((simd_dot(dxz, r2) / n).rounded()) + half
            guard i > 0, i < width - 1 else { continue }
            let j = Int((simd_dot(dxz, f2) / n).rounded()) + half
            guard j > 0, j < width - 1 else { continue }
            searchGrid[i * width + j] = 1
        }
        // 把自己站的位置清出来
        for (ci, cj) in Rover.circleCells {
            let x = half + ci, y = half + cj
            if x >= 0, x < width, y >= 0, y < width { searchGrid[x * width + y] = 0 }
        }
        return bestLineDirection()
    }

    /// 0°, +2°, −2°, +4° … ±90° 扇形扫描；第一条通畅射线即答案；全堵则选最远的方向，
    /// 小角度绕行钳到 ±30°（太小的修正没意义）
    private func bestLineDirection() -> Float {
        var degree: Float = 0
        var bestDir: Float = 10
        var bestDist: Float = -1
        let half = Rover.searchWidthHalf
        while abs(degree) <= 90 {
            let rad = (90 - degree) * .pi / 180
            let x = Int((Rover.paddedDistance * cos(rad) / Rover.nodeSize).rounded())
            let y = Int((Rover.paddedDistance * sin(rad) / Rover.nodeSize).rounded())
            let (hit, dist) = attemptLine(targetX: x + half, targetY: y + half)
            if !hit { return degree }
            if dist > bestDist { bestDir = degree; bestDist = dist }
            if degree > 0 { degree = -degree } else { degree = -degree + 2 }
        }
        if bestDir < 0, bestDir > -30 { bestDir = -30 }
        if bestDir > 0, bestDir < 30 { bestDir = 30 }
        return bestDir
    }

    /// Amanatides-Woo 网格射线遍历
    private func attemptLine(targetX: Int, targetY: Int) -> (Bool, Float) {
        let half = Rover.searchWidthHalf, width = Rover.searchWidth
        var x = half, y = half
        let dX = Float(targetX - x) + 1e-6, dY = Float(targetY - y) + 1e-6
        let stepX = dX > 0 ? 1 : -1, stepY = dY > 0 ? 1 : -1
        let dist = (dX * dX + dY * dY).squareRoot()
        let tDeltaX = abs(dist / dX), tDeltaY = abs(dist / dY)
        var tMaxX = tDeltaX, tMaxY = tDeltaY
        var hit = false
        while x != targetX || y != targetY {
            if tMaxX < tMaxY { tMaxX += tDeltaX; x += stepX }
            else { tMaxY += tDeltaY; y += stepY }
            guard x >= 0, x < width, y >= 0, y < width else { break }
            if searchGrid[x * width + y] == 1 { hit = true; break }
        }
        let fx = Float(x - half), fy = Float(y - half)
        return (hit, fx * fx + fy * fy)
    }
}
