## 0.2.0

- Fix EXC_BAD_ACCESS: thread-safe actor isolation with lock-protected static state
- Fix ARC ownership mismatch in AdServices ObjC bridge
- Fix unsafe memory access in DeviceInfo utsname
- Add deep-copy for cross-actor dictionary parameters
- Add concurrency tests
- Use SDK key as sole credential — `configure(apiKey:)` replaces `configure(appId:)`
- Centralize version string via `AppReferVersion.current`

## 0.1.0

- Initial release
