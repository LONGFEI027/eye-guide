package asia.feizhu.glassprobe;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.graphics.ImageFormat;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.ImageReader;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Size;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.util.Arrays;

/**
 * 相机探针：枚举所有摄像头 → 逐个尝试打开 → 把能打开的第一路画到屏幕上，
 * 角落实时显示 相机ID/分辨率/帧率。眼镜里看到实时画面 = 连续取帧成立。
 * 全程只读相机，不写任何系统设置；卸载即还原。
 */
public class ProbeActivity extends Activity {
    private TextView hud;
    private SurfaceView preview;
    private HandlerThread camThread;
    private Handler camHandler;
    private CameraDevice camera;
    private ImageReader reader;           // 额外一路 YUV，用来数帧率（证明取得到帧数据而不只是预览）
    private long frameCount = 0;
    private long windowStart = 0;
    private double fps = 0;
    private String line1 = "探针启动…";
    private String camList = "";
    private int tryIndex = 0;
    private String[] ids = new String[0];

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        FrameLayout root = new FrameLayout(this);
        preview = new SurfaceView(this);
        root.addView(preview);
        hud = new TextView(this);
        hud.setTextColor(Color.GREEN);
        hud.setBackgroundColor(0x80000000);
        hud.setTextSize(18);
        hud.setPadding(24, 16, 24, 16);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.LEFT);
        root.addView(hud, lp);
        setContentView(root);

        camThread = new HandlerThread("cam");
        camThread.start();
        camHandler = new Handler(camThread.getLooper());

        preview.getHolder().addCallback(new SurfaceHolder.Callback() {
            @Override public void surfaceCreated(SurfaceHolder h) { ensurePermissionThenOpen(); }
            @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) {}
            @Override public void surfaceDestroyed(SurfaceHolder h) { closeCamera(); }
        });
        hudLoop();
    }

    /// targetSdk≥23：相机要运行时权限。弹窗会出现在眼镜显示里，用镜腿触控板确认。
    private void ensurePermissionThenOpen() {
        if (checkSelfPermission(android.Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            enumerateAndOpen();
        } else {
            line1 = "请求相机权限中…（如眼镜里有弹窗，用触控板确认）";
            requestPermissions(new String[]{android.Manifest.permission.CAMERA}, 1);
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        if (code == 1 && results.length > 0 && results[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            enumerateAndOpen();
        } else {
            line1 = "❌ 相机权限被拒（结果码 " + (results.length > 0 ? results[0] : -999) + "）";
        }
    }

    private void hudLoop() {
        hud.postDelayed(() -> {
            hud.setText(line1 + "\n可见相机: [" + camList + "]\n帧率: " + String.format("%.1f", fps) + " fps  累计 " + frameCount + " 帧");
            hudLoop();
        }, 500);
    }

    private void enumerateAndOpen() {
        CameraManager mgr = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        try {
            ids = mgr.getCameraIdList();
            camList = String.join(",", ids);
            line1 = "枚举到 " + ids.length + " 路相机，逐个尝试…";
        } catch (Exception e) {
            line1 = "枚举相机失败: " + e;
            return;
        }
        tryIndex = 0;
        tryOpen();
    }

    private void tryOpen() {
        if (tryIndex >= ids.length) { line1 = "❌ 所有相机都打不开（被系统占用或无权限）"; return; }
        String id = ids[tryIndex];
        CameraManager mgr = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        try {
            CameraCharacteristics ch = mgr.getCameraCharacteristics(id);
            StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            Size[] sizes = map != null ? map.getOutputSizes(ImageFormat.YUV_420_888) : null;
            Size pick = pick(sizes);
            line1 = "尝试打开相机 " + id + " @" + pick + " …";
            mgr.openCamera(id, new CameraDevice.StateCallback() {
                @Override public void onOpened(CameraDevice cam) { camera = cam; startSession(cam, pick, id); }
                @Override public void onDisconnected(CameraDevice cam) { line1 = "相机 " + id + " 断开"; cam.close(); nextCam(); }
                @Override public void onError(CameraDevice cam, int err) { line1 = "相机 " + id + " 打开失败 err=" + err; cam.close(); nextCam(); }
            }, camHandler);
        } catch (SecurityException se) {
            line1 = "❌ 没有相机权限（运行时权限未授予）";
        } catch (Exception e) {
            line1 = "相机 " + id + " 异常: " + e;
            nextCam();
        }
    }

    private void nextCam() { tryIndex++; runOnUiThread(this::tryOpen); }

    private Size pick(Size[] sizes) {
        if (sizes == null || sizes.length == 0) return new Size(640, 480);
        Size best = sizes[0];
        for (Size s : sizes) {
            int d = Math.abs(s.getWidth() * s.getHeight() - 1280 * 720);
            int bd = Math.abs(best.getWidth() * best.getHeight() - 1280 * 720);
            if (d < bd) best = s;
        }
        return best;
    }

    private void startSession(CameraDevice cam, Size size, String id) {
        try {
            reader = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.YUV_420_888, 3);
            reader.setOnImageAvailableListener(r -> {
                android.media.Image img = r.acquireLatestImage();
                if (img != null) {
                    img.close();
                    frameCount++;
                    long now = System.nanoTime();
                    if (windowStart == 0) windowStart = now;
                    long dt = now - windowStart;
                    if (dt > 1_000_000_000L) { fps = frameCount * 1e9 / dt; }
                    if (dt > 5_000_000_000L) { windowStart = now; frameCount = 0; }
                }
            }, camHandler);
            preview.getHolder().setFixedSize(size.getWidth(), size.getHeight());
            CaptureRequest.Builder req = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            req.addTarget(preview.getHolder().getSurface());
            req.addTarget(reader.getSurface());
            cam.createCaptureSession(Arrays.asList(preview.getHolder().getSurface(), reader.getSurface()),
                    new CameraCaptureSession.StateCallback() {
                        @Override public void onConfigured(CameraCaptureSession s) {
                            try {
                                s.setRepeatingRequest(req.build(), null, camHandler);
                                line1 = "✅ 相机 " + id + " 连续出帧中 @" + size;
                            } catch (Exception e) { line1 = "下发预览失败: " + e; }
                        }
                        @Override public void onConfigureFailed(CameraCaptureSession s) {
                            line1 = "会话配置失败（相机 " + id + "）"; nextCam();
                        }
                    }, camHandler);
        } catch (Exception e) {
            line1 = "建会话异常: " + e;
            nextCam();
        }
    }

    private void closeCamera() {
        if (camera != null) { camera.close(); camera = null; }
        if (reader != null) { reader.close(); reader = null; }
    }

    @Override protected void onDestroy() { closeCamera(); camThread.quitSafely(); super.onDestroy(); }
}
