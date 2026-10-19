#pragma once

namespace rokid {

class Caps;

class Member {
public:
  virtual ~Member() = default;

  virtual char type() const = 0;

  static const char* typeStr(char type) {
    switch (type) {
    case CAPS_MEMBER_TYPE_INT32:
      return "int32";
    case CAPS_MEMBER_TYPE_UINT32:
      return "uint32";
    case CAPS_MEMBER_TYPE_INT64:
      return "int64";
    case CAPS_MEMBER_TYPE_UINT64:
      return "uint64";
    case CAPS_MEMBER_TYPE_FLOAT:
      return "float";
    case CAPS_MEMBER_TYPE_DOUBLE:
      return "double";
    case CAPS_MEMBER_TYPE_STRING:
      return "string";
    case CAPS_MEMBER_TYPE_BINARY:
      return "binary";
    case CAPS_MEMBER_TYPE_OBJECT:
      return "object";
    case CAPS_MEMBER_TYPE_VOID:
      return "void";
    }
    return "invalid";
  }
};

class VoidMember : public Member {
public:
  char type() const { return 'V'; }
};

// T: type
// TC: type char
// S: size
template <typename T, char TC, int32_t S>
class NumberMember : public Member {
public:
  NumberMember(T v) {
    value.number = v;
  }

  char type() const { return TC; }

public:
  union {
    T number;
    char data[S];
  } value;
};
typedef NumberMember<int32_t, CAPS_MEMBER_TYPE_INT32, 4> Int32Member;
typedef NumberMember<uint32_t, CAPS_MEMBER_TYPE_UINT32, 4> Uint32Member;
typedef NumberMember<float, CAPS_MEMBER_TYPE_FLOAT, 4> FloatMember;
typedef NumberMember<int64_t, CAPS_MEMBER_TYPE_INT64, 8> Int64Member;
typedef NumberMember<uint64_t, CAPS_MEMBER_TYPE_UINT64, 8> Uint64Member;
typedef NumberMember<double, CAPS_MEMBER_TYPE_DOUBLE, 8> DoubleMember;

class StringMember : public Member {
public:
  StringMember(const char* v) {
    data = v;
  }

  StringMember(const void* v, uint32_t l) {
    data.assign(reinterpret_cast<const char*>(v), l);
  }

  char type() const { return CAPS_MEMBER_TYPE_STRING; }

public:
  std::string data;
};

class BinaryMember : public Member {
public:
  BinaryMember(const void* v, uint32_t l) {
    if (l > 0) {
      data.resize(l);
      memcpy(data.data(), v, l);
    }
  }

  char type() const { return CAPS_MEMBER_TYPE_BINARY; }

public:
  std::vector<char> data;
};

class ObjectMember : public Member {
public:
  ObjectMember(const Caps& o) {
    value = o;
  }

  ObjectMember(Caps&& o) {
    value = std::move(o);
  }

  ObjectMember(const uint8_t* data, uint32_t size) {
    value.parse(data, size);
  }

  char type() const { return CAPS_MEMBER_TYPE_OBJECT; }

public:
  Caps value;
};

typedef std::shared_ptr<Int32Member> Int32MemberPointer;
typedef std::shared_ptr<Int64Member> Int64MemberPointer;
typedef std::shared_ptr<Uint32Member> Uint32MemberPointer;
typedef std::shared_ptr<Uint64Member> Uint64MemberPointer;
typedef std::shared_ptr<FloatMember> FloatMemberPointer;
typedef std::shared_ptr<DoubleMember> DoubleMemberPointer;
typedef std::shared_ptr<StringMember> StringMemberPointer;
typedef std::shared_ptr<BinaryMember> BinaryMemberPointer;
typedef std::shared_ptr<ObjectMember> ObjectMemberPointer;
typedef std::shared_ptr<VoidMember> VoidMemberPointer;

} // namespace rokid
