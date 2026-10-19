#include <stdio.h>
#include <stdarg.h>
#include <inttypes.h>
#include <string.h>
#include <arpa/inet.h>
#include <stdexcept>
#include <algorithm>
#include "caps.h"
#include "defs.h"
#include "member.h"
#include "leb128.h"

using namespace std;

namespace rokid {

template <typename E>
void throwException(const char* format, ...) {
  char msg[64];
  va_list ap;
  va_start(ap, format);
  vsnprintf(msg, sizeof(msg), format, ap);
  va_end(ap);
  throw E(msg);
}

Caps::Caps() {
  aliveIndicator = make_shared<int32_t>(0);
}

Caps::Caps(initializer_list<Caps::Value> list) {
  aliveIndicator = make_shared<int32_t>(0);
  for_each(list.begin(), list.end(), [this](const Caps::Value& v) {
    members.push_back(v.member);
  });
}

Caps::~Caps() {
  aliveIndicator.reset();
  clearMembers();
}

Caps::Caps(const Caps& o) {
  members = o.members;
  aliveIndicator = make_shared<int32_t>(0);
}

Caps::Caps(Caps&& o) {
  members = move(o.members);
  aliveIndicator = make_shared<int32_t>(0);
}

Caps& Caps::operator = (const Caps& o) {
  members = o.members;
  return *this;
}

Caps& Caps::operator = (Caps&& o) {
  members = move(o.members);
  return *this;
}

void Caps::write() {
  members.push_back(make_shared<VoidMember>());
}

void Caps::write(int32_t v) {
  members.push_back(make_shared<Int32Member>(v));
}

void Caps::write(uint32_t v) {
  members.push_back(make_shared<Uint32Member>(v));
}

void Caps::write(float v) {
  members.push_back(make_shared<FloatMember>(v));
}

void Caps::write(int64_t v) {
  members.push_back(make_shared<Int64Member>(v));
}

void Caps::write(uint64_t v) {
  members.push_back(make_shared<Uint64Member>(v));
}

void Caps::write(double v) {
  members.push_back(make_shared<DoubleMember>(v));
}

void Caps::write(const char* v) {
  members.push_back(make_shared<StringMember>(v));
}

void Caps::write(const void* data, uint32_t size) {
  members.push_back(make_shared<BinaryMember>(data, size));
}

void Caps::write(const Caps& v) {
  members.push_back(make_shared<ObjectMember>(v));
}

uint32_t Caps::serialize(void* out, uint32_t size) const {
  if (out == nullptr)
    throw invalid_argument("out is nullptr");
  if (size <= HEADER_SIZE)
    throw out_of_range("out buffer size too small");
  uint8_t* p = reinterpret_cast<uint8_t*>(out);
  p += HEADER_SIZE;
  auto psize = size - (p - reinterpret_cast<uint8_t*>(out));
  p = serializeMemberDesc(p, psize);
  psize = size - (p - reinterpret_cast<uint8_t*>(out));
  p = serializeMembers(p, psize);
  uint32_t totalSize = p - reinterpret_cast<uint8_t*>(out);
  serializeHeader(reinterpret_cast<uint8_t*>(out), totalSize);
  return totalSize;
}

void Caps::serializeHeader(uint8_t* out, uint32_t size) const {
  size = htonl(size);
  memcpy(out, &size, sizeof(size));
  out[sizeof(size)] = CAPS_VERSION;
}

uint8_t* Caps::serializeMemberDesc(uint8_t* out, uint32_t size) const {
  auto p = uleb128Write((uint32_t)members.size(), out, size);
  auto psize = size - (p - out);
  if (psize < members.size())
    throw out_of_range("out buffer size too small");
  for_each(members.begin(), members.end(), [&p](const MemberPointer& member) {
    p[0] = member->type();
    ++p;
  });
  return p;
}

static void leWriteFloat(float v, uint8_t* out) {
  uint32_t n = *(uint32_t*)(&v);
  out[0] = n;
  out[1] = n >> 8;
  out[2] = n >> 16;
  out[3] = n >> 24;
}

static void leWriteDouble(double v, uint8_t* out) {
  uint64_t n = *(uint64_t*)(&v);
  out[0] = n;
  out[1] = n >> 8;
  out[2] = n >> 16;
  out[3] = n >> 24;
  out[4] = n >> 32;
  out[5] = n >> 40;
  out[6] = n >> 48;
  out[7] = n >> 56;
}

uint8_t* Caps::serializeMembers(uint8_t* out, uint32_t size) const {
  auto p = out;
  for_each(members.begin(), members.end(),
      [&p, out, size](const MemberPointer& member) {
    auto psize = size - (p - out);
    switch (member->type()) {
    case CAPS_MEMBER_TYPE_INT32:
      p = leb128Write(static_pointer_cast<Int32Member>(member)->value.number,
          p, psize);
      break;
    case CAPS_MEMBER_TYPE_UINT32:
      p = uleb128Write(static_pointer_cast<Uint32Member>(member)->value.number,
          p, psize);
      break;
    case CAPS_MEMBER_TYPE_INT64:
      p = leb128Write(static_pointer_cast<Int64Member>(member)->value.number,
          p, psize);
      break;
    case CAPS_MEMBER_TYPE_UINT64:
      p = uleb128Write(static_pointer_cast<Uint64Member>(member)->value.number,
          p, psize);
      break;
    case CAPS_MEMBER_TYPE_FLOAT:
      if (psize < sizeof(float))
        throw out_of_range("out buffer size too small");
      leWriteFloat(static_pointer_cast<FloatMember>(member)->value.number, p);
      p += sizeof(float);
      break;
    case CAPS_MEMBER_TYPE_DOUBLE:
      if (psize < sizeof(double))
        throw out_of_range("out buffer size too small");
      leWriteDouble(static_pointer_cast<DoubleMember>(member)->value.number, p);
      p += sizeof(double);
      break;
    case CAPS_MEMBER_TYPE_STRING: {
      auto m = static_pointer_cast<StringMember>(member);
      uint32_t dataSize = m->data.length();
      p = uleb128Write(dataSize, p, psize);
      psize = size - (p - out);
      if (psize < dataSize)
        throw out_of_range("out buffer size too small");
      memcpy(p, m->data.data(), dataSize);
      p += dataSize;
      break;
    }
    case CAPS_MEMBER_TYPE_BINARY: {
      auto m = static_pointer_cast<BinaryMember>(member);
      uint32_t dataSize = m->data.size();
      p = uleb128Write(dataSize, p, psize);
      psize = size - (p - out);
      if (psize < dataSize)
        throw out_of_range("out buffer size too small");
      memcpy(p, m->data.data(), dataSize);
      p += dataSize;
      break;
    }
    case CAPS_MEMBER_TYPE_OBJECT:
      p += static_pointer_cast<ObjectMember>(member)->value.serialize(p, psize);
      break;
    case CAPS_MEMBER_TYPE_VOID:
      break;
    default:
      throwException<range_error>("unknown member type '%c'", member->type());
    }
  });
  return p;
}

static uint32_t beReadUint32(const uint8_t* in) {
  uint32_t v;
  v = in[3];
  v |= in[2] << 8;
  v |= in[1] << 16;
  v |= in[0] << 24;
  return v;
}

void Caps::parse(const void* in, uint32_t size) {
  if (in == nullptr || size <= HEADER_SIZE)
    throw invalid_argument("'in' is nullptr or size too small");
  uint32_t totalSize;
  auto p = reinterpret_cast<const uint8_t*>(in);
  parseHeader(p, totalSize);
  if (totalSize != size)
    throwException<invalid_argument>("incorrect size, expect %u, actual %u",
        totalSize, size);
  uint32_t off = HEADER_SIZE;
  // uint32_t curSize = p - reinterpret_cast<const uint8_t*>(in);
  uint32_t descLen;
  off += uleb128Read(p + off, size - off, descLen);
  auto desc = p + off;
  off += descLen;
  if (off > size)
    throw domain_error("input data may corrupted");
  clearMembers();
  parseMembers(p + off, size - off, desc, descLen);
}

int32_t Caps::parse2(const void* in, uint32_t size) {
  if (in == nullptr)
    return -1;
  if (size <= HEADER_SIZE)
    return 0;
  uint32_t totalSize;
  auto p = reinterpret_cast<const uint8_t*>(in);
  try {
    parseHeader(p, totalSize);
  } catch (exception& e) {
    return -1;
  }
  if (totalSize > size)
    return 0;
  uint32_t off = HEADER_SIZE;
  uint32_t descLen;
  off += uleb128Read(p + off, totalSize - off, descLen);
  auto desc = p + off;
  off += descLen;
  if (off > totalSize)
    return -1;
  clearMembers();
  try {
    parseMembers(p + off, totalSize - off, desc, descLen);
  } catch (exception& e) {
    return -1;
  }
  return totalSize;
}

const uint8_t* Caps::parseHeader(const uint8_t* p, uint32_t& totalSize) {
  totalSize = beReadUint32(p);
  p += sizeof(uint32_t);
  auto version = p[0];
  if (version != CAPS_VERSION)
    throwException<domain_error>("incorrect caps version, expect %u, actual %u",
        CAPS_VERSION, version);
  ++p;
  return p;
}

static float leReadFloat(const uint8_t* in) {
  union {
    float f;
    uint32_t i;
  } r;
  r.i = in[0];
  r.i |= in[1] << 8;
  r.i |= in[2] << 16;
  r.i |= in[3] << 24;
  return r.f;
}

static double leReadDouble(const uint8_t* in) {
  union {
    double f;
    uint32_t i[2];
  } r;
  r.i[0] = in[0];
  r.i[0] |= in[1] << 8;
  r.i[0] |= in[2] << 16;
  r.i[0] |= in[3] << 24;
  r.i[1] = in[4];
  r.i[1] |= in[5] << 8;
  r.i[1] |= in[6] << 16;
  r.i[1] |= in[7] << 24;
  return r.f;
}

void Caps::parseMembers(const uint8_t* in, uint32_t psize,
    const uint8_t* desc, uint32_t descLen) {
  uint32_t i;
  uint32_t off{0};
  for (i = 0; i < descLen; ++i) {
    switch (desc[i]) {
    case CAPS_MEMBER_TYPE_INT32: {
      int32_t v;
      off += leb128Read(in + off, psize - off, v);
      members.push_back(make_shared<Int32Member>(v));
      break;
    }
    case CAPS_MEMBER_TYPE_INT64: {
      int64_t v;
      off += leb128Read(in + off, psize - off, v);
      members.push_back(make_shared<Int64Member>(v));
      break;
    }
    case CAPS_MEMBER_TYPE_UINT32: {
      uint32_t v;
      off += uleb128Read(in + off, psize - off, v);
      members.push_back(make_shared<Uint32Member>(v));
      break;
    }
    case CAPS_MEMBER_TYPE_UINT64: {
      uint64_t v;
      off += uleb128Read(in + off, psize - off, v);
      members.push_back(make_shared<Uint64Member>(v));
      break;
    }
    case CAPS_MEMBER_TYPE_FLOAT: {
      float v;
      if (psize - off < sizeof(float))
        throwException<domain_error>("input data may corrupted");
      v = leReadFloat(in + off);
      members.push_back(make_shared<FloatMember>(v));
      off += sizeof(float);
      break;
    }
    case CAPS_MEMBER_TYPE_DOUBLE: {
      double v;
      if (psize - off < sizeof(double))
        throwException<domain_error>("input data may corrupted");
      v = leReadDouble(in + off);
      members.push_back(make_shared<DoubleMember>(v));
      off += sizeof(double);
      break;
    }
    case CAPS_MEMBER_TYPE_STRING: {
      uint32_t v;
      off += uleb128Read(in + off, psize - off, v);
      if (psize - off < v)
        throwException<domain_error>("input data may corrupted");
      members.push_back(make_shared<StringMember>(in + off, v));
      off += v;
      break;
    }
    case CAPS_MEMBER_TYPE_BINARY: {
      uint32_t v;
      off += uleb128Read(in + off, psize - off, v);
      if (psize - off < v)
        throwException<domain_error>("input data may corrupted");
      members.push_back(make_shared<BinaryMember>(in + off, v));
      off += v;
      break;
    }
    case CAPS_MEMBER_TYPE_OBJECT: {
      if (psize - off < sizeof(uint32_t))
        throwException<domain_error>("input data may corrupted");
      auto sz = beReadUint32(in + off);
      if (off + sz > psize)
        throwException<domain_error>("input data may corrupted");
      members.push_back(make_shared<ObjectMember>(in + off, sz));
      off += sz;
      break;
    }
    case CAPS_MEMBER_TYPE_VOID:
      members.push_back(make_shared<VoidMember>());
      break;
    default:
      throwException<domain_error>("unknown member type %c, input data may corrupted",
          desc[i]);
    }
  }
}

void Caps::clearMembers() {
  members.clear();
}

Caps::iterator Caps::iterate(uint32_t idx) const {
  iterator it;
  it.members = &members;
  it.aliveIndicator = aliveIndicator;
  it.index = idx;
  return it;
}

bool Caps::iterator::hasNext() const {
  auto ai = aliveIndicator.lock();
  if (ai == nullptr)
    return false;
  return index < members->size();
}

Caps::Value Caps::iterator::next() const {
  auto ai = aliveIndicator.lock();
  if (ai != nullptr && index < members->size())
    return members->at(index++);
  throw out_of_range("no more member");
}

bool Caps::empty() const {
  return size() == 0;
}

uint32_t Caps::size() const {
  return members.size();
}

uint32_t Caps::dump(char* out, uint32_t size) const {
  if (out == nullptr && size != 0)
    throw invalid_argument("out is nullptr");
  return dump(0, out, size);
}

void Caps::clear() {
  clearMembers();
}

uint32_t Caps::getBinarySize(const void* in, uint32_t size) {
  if (in == nullptr)
    throwException<invalid_argument>("input data is nullptr");
  if (size < sizeof(uint32_t))
    throwException<out_of_range>("input size %u < 4", size);
  return beReadUint32(reinterpret_cast<const uint8_t*>(in));
}

static int32_t outputIndent(char* out, uint32_t size, uint32_t indent) {
  auto p = out;
  auto psize = size;
  static const char* INDENT_STRING = "> ";
  while (indent) {
    --indent;
    auto c = snprintf(p, psize, "%s", INDENT_STRING);
    if ((uint32_t)c > psize)
      return -1;
    p += c;
    psize -= c;
  }
  return p - out;
}

uint32_t Caps::dump(uint32_t indent, char* out, uint32_t size) const {
  auto p = out;
  auto psize = size;
  uint32_t idx{0};
  if (size == 0)
    return 0;
  auto it = members.begin();
  while (it != members.end()) {
    auto c = outputIndent(p, psize, indent);
    if (c < 0)
      return size - 1;
    p += c;
    psize -= c;
    switch ((*it)->type()) {
    case CAPS_MEMBER_TYPE_INT32:
      c = snprintf(p, psize, "%u: %" PRIi32 "\n", idx, static_pointer_cast<Int32Member>(*it)->value.number);
      break;
    case CAPS_MEMBER_TYPE_UINT32:
      c = snprintf(p, psize, "%u: %" PRIu32 "u\n", idx, static_pointer_cast<Uint32Member>(*it)->value.number);
      break;
    case CAPS_MEMBER_TYPE_INT64:
      c = snprintf(p, psize, "%u: %" PRIi64 "l\n", idx, static_pointer_cast<Int64Member>(*it)->value.number);
      break;
    case CAPS_MEMBER_TYPE_UINT64:
      c = snprintf(p, psize, "%u: %" PRIu64 "ul\n", idx, static_pointer_cast<Uint64Member>(*it)->value.number);
      break;
    case CAPS_MEMBER_TYPE_FLOAT:
      c = snprintf(p, psize, "%u: %f\n", idx, static_pointer_cast<FloatMember>(*it)->value.number);
      break;
    case CAPS_MEMBER_TYPE_DOUBLE:
      c = snprintf(p, psize, "%u: %lfL\n", idx, static_pointer_cast<DoubleMember>(*it)->value.number);
      break;
    case CAPS_MEMBER_TYPE_STRING:
      c = snprintf(p, psize, "%u: \"%s\"\n", idx, static_pointer_cast<StringMember>(*it)->data.c_str());
      break;
    case CAPS_MEMBER_TYPE_BINARY:
      c = snprintf(p, psize, "%u: binary data %zd bytes\n", idx++, static_pointer_cast<BinaryMember>(*it)->data.size());
      break;
    case CAPS_MEMBER_TYPE_OBJECT:
      c = snprintf(p, psize, "%u: caps\n", idx);
      if ((uint32_t)c > psize)
        return size - 1;
      p += c;
      psize -= c;
      c = static_pointer_cast<ObjectMember>(*it)->value.dump(indent + 1, p, psize);
      break;
    case CAPS_MEMBER_TYPE_VOID:
      c = snprintf(p, psize, "%u: void\n", idx);
      break;
    default:
      throwException<domain_error>("unknown member type '%c', caps may corrupted", (*it)->type());
    }
    if ((uint32_t)c > psize)
      return size - 1;
    p += c;
    psize -= c;
    ++idx;
    ++it;
  }
  auto r = p - out;
  if (r == 0)
    out[0] = '\0';
  return r;
}

Caps::Value Caps::at(uint32_t i) const {
  if (i >= members.size())
    throwException<out_of_range>("index %u out of range", i);
  return members[i];
}

Caps::Value::Value(MemberPointer m) : member{m} {
}

Caps::Value::Value(bool v) {
  member = make_shared<Uint32Member>(v);
}

Caps::Value::Value(int8_t v) {
  member = make_shared<Int32Member>(v);
}

Caps::Value::Value(uint8_t v) {
  member = make_shared<Uint32Member>(v);
}

Caps::Value::Value(int16_t v) {
  member = make_shared<Int32Member>(v);
}

Caps::Value::Value(uint16_t v) {
  member = make_shared<Uint32Member>(v);
}

Caps::Value::Value(int32_t v) {
  member = make_shared<Int32Member>(v);
}

Caps::Value::Value(uint32_t v) {
  member = make_shared<Uint32Member>(v);
}

Caps::Value::Value(int64_t v) {
  member = make_shared<Int64Member>(v);
}

Caps::Value::Value(uint64_t v) {
  member = make_shared<Uint64Member>(v);
}

Caps::Value::Value(float v) {
  member = make_shared<FloatMember>(v);
}

Caps::Value::Value(double v) {
  member = make_shared<DoubleMember>(v);
}

Caps::Value::Value(const char* v) {
  member = make_shared<StringMember>(v);
}

Caps::Value::Value(const string& v) {
  member = make_shared<StringMember>(v.c_str());
}

Caps::Value::Value() {
  member = make_shared<VoidMember>();
}

Caps::Value::Value(std::initializer_list<Value> list) {
  member = make_shared<ObjectMember>(Caps(list));
}

Caps::Value::operator bool() const {
  if (member->type() != CAPS_MEMBER_TYPE_UINT32)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_UINT32),
        Member::typeStr(member->type()));
  return static_pointer_cast<Int32Member>(member)->value.number;
}

Caps::Value::operator int8_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_INT32)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_INT32),
        Member::typeStr(member->type()));
  return static_pointer_cast<Int32Member>(member)->value.number;
}

Caps::Value::operator uint8_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_UINT32)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_UINT32),
        Member::typeStr(member->type()));
  return static_pointer_cast<Int32Member>(member)->value.number;
}

Caps::Value::operator int16_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_INT32)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_INT32),
        Member::typeStr(member->type()));
  return static_pointer_cast<Int32Member>(member)->value.number;
}

Caps::Value::operator uint16_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_UINT32)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_UINT32),
        Member::typeStr(member->type()));
  return static_pointer_cast<Int32Member>(member)->value.number;
}

Caps::Value::operator int32_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_INT32)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_INT32),
        Member::typeStr(member->type()));
  return static_pointer_cast<Int32Member>(member)->value.number;
}

Caps::Value::operator uint32_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_UINT32)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_UINT32),
        Member::typeStr(member->type()));
  return static_pointer_cast<Uint32Member>(member)->value.number;
}

Caps::Value::operator int64_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_INT64)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_INT64),
        Member::typeStr(member->type()));
  return static_pointer_cast<Int64Member>(member)->value.number;
}

Caps::Value::operator uint64_t() const {
  if (member->type() != CAPS_MEMBER_TYPE_UINT64)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_UINT64),
        Member::typeStr(member->type()));
  return static_pointer_cast<Uint64Member>(member)->value.number;
}

Caps::Value::operator float() const {
  if (member->type() != CAPS_MEMBER_TYPE_FLOAT)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_FLOAT),
        Member::typeStr(member->type()));
  return static_pointer_cast<FloatMember>(member)->value.number;
}

Caps::Value::operator double() const {
  if (member->type() != CAPS_MEMBER_TYPE_DOUBLE)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_DOUBLE),
        Member::typeStr(member->type()));
  return static_pointer_cast<DoubleMember>(member)->value.number;
}

Caps::Value::operator const string&() const {
  if (member->type() != CAPS_MEMBER_TYPE_STRING)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_STRING),
        Member::typeStr(member->type()));
  return static_pointer_cast<StringMember>(member)->data;
}

Caps::Value::operator const char*() const {
  if (member->type() != CAPS_MEMBER_TYPE_STRING)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_STRING),
        Member::typeStr(member->type()));
  return static_pointer_cast<StringMember>(member)->data.c_str();
}

Caps::Value::operator Caps() const {
  if (member->type() != CAPS_MEMBER_TYPE_OBJECT)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_OBJECT),
        Member::typeStr(member->type()));
  return static_pointer_cast<ObjectMember>(member)->value;
}

Caps::Value::operator const vector<char>&() const {
  if (member->type() != CAPS_MEMBER_TYPE_BINARY)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_BINARY),
        Member::typeStr(member->type()));
  return static_pointer_cast<BinaryMember>(member)->data;
}

void Caps::Value::get(vector<char>& out) const {
  if (member->type() != CAPS_MEMBER_TYPE_BINARY)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_BINARY),
        Member::typeStr(member->type()));
  auto m = static_pointer_cast<BinaryMember>(member);
  out.assign(m->data.begin(), m->data.end());
}

uint32_t Caps::Value::read(void* out, uint32_t size) const {
  if (member->type() != CAPS_MEMBER_TYPE_BINARY)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_BINARY),
        Member::typeStr(member->type()));
  auto m = static_pointer_cast<BinaryMember>(member);
  auto dataSize = m->data.size();
  uint32_t cpsz;
  if (size > dataSize)
    cpsz = dataSize;
  else
    cpsz = size;
  memcpy(out, m->data.data(), cpsz);
  return cpsz;
}

uint32_t Caps::Value::size() const {
  if (member->type() != CAPS_MEMBER_TYPE_BINARY)
    throwException<type_error>("expect %s, but is %s",
        Member::typeStr(CAPS_MEMBER_TYPE_BINARY),
        Member::typeStr(member->type()));
  auto m = static_pointer_cast<BinaryMember>(member);
  return m->data.size();
}

char Caps::Value::type() const {
  return member->type();
}

} // namespace rokid
