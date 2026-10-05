# Android (phase 2, not in v1)

There is no Android library in v1. On Android, the `AppsFlyer` autoload warns once on `init()` and turns every call into a no-op. Phase 2 will register the same `AppsFlyerGodotPlugin` singleton with the same methods and signals. It will ship as one AAR plus a Maven dependency and require a Gradle build. iOS-only features (ATT, SKAN, Apple app id, associated domains) will stay no-ops on Android, and Android will not add `waitForCustomerUserId` to the shared API.
