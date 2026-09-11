#pragma once

#include <windows.h>
#include <cstdint>
#include <string>

inline std::wstring KioskDirectory() {
  wchar_t path[32768] = {};
  const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
  if (length == 0 || length >= 32768) return {};
  const std::wstring full(path, length);
  const auto slash = full.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring{} : full.substr(0, slash);
}

// Stable across builds; separate installations and Windows sessions do not
// stop each other's players. No machine-wide service or administrator needed.
inline std::wstring KioskObjectName(const std::wstring& directory,
                                   const wchar_t* kind) {
  std::wstring normalized(directory);
  CharLowerBuffW(normalized.data(), static_cast<DWORD>(normalized.size()));
  std::uint64_t hash = 14695981039346656037ull;
  for (wchar_t c : normalized) {
    hash ^= static_cast<std::uint16_t>(c);
    hash *= 1099511628211ull;
  }
  return L"Local\\SignageX_" + std::to_wstring(hash) + L"_" + kind;
}

class KioskHandle {
 public:
  explicit KioskHandle(HANDLE value = nullptr) : value_(value) {}
  ~KioskHandle() {
    if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
  }
  KioskHandle(const KioskHandle&) = delete;
  KioskHandle& operator=(const KioskHandle&) = delete;
  HANDLE get() const { return value_; }
 private:
  HANDLE value_;
};
