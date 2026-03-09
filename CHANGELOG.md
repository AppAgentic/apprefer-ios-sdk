## 0.3.0

- Harden SDK to never crash host app
- Remove throws from all public API methods — silently no-op if called before configure()
- Fix force unwrap crash in DeviceInfo utsname pointer
- Fix potential double-resume crash in URLSession continuation
- Fix simulator crash: skip AdServices (throws uncatchable NSException)
- Use proper AdServices import instead of unsafe objc_msgSend bridge

## 0.2.1

- Fix kill switch response key (`sdk_enabled` → `sdkEnabled`)

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
