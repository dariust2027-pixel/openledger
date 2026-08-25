# Building & Releasing OpenLedger

## Prerequisites
| Platform | Needs |
|---|---|
| Android | Flutter SDK, Android Studio/SDK, Java 17 |
| Windows desktop | Flutter SDK + **Visual Studio with "Desktop development with C++" workload** |
| iOS/macOS | macOS machine with Xcode (build on CI service like Codemagic if you have no Mac) |

## Daily development
```powershell
cd app
flutter pub get
flutter run                 # picks connected device / Windows desktop
flutter analyze             # must stay clean
flutter test                # unit tests
```

## Launcher icons (after changing assets/icon/app_icon.png)
```powershell
dart run flutter_launcher_icons
```

## Android
```powershell
flutter build apk --release          # sideload: build\app\outputs\flutter-apk\
flutter build appbundle --release    # Play Store upload
```
**Signing for Play Store:** create `android/key.properties` (git-ignored) with your
keystore config — see https://docs.flutter.dev/deployment/android

## Windows
Requires VS C++ toolchain once:
```powershell
flutter build windows --release      # output: build\windows\x64\runner\Release\
```
Package as MSIX (optional): `dart pub add msix; dart run msix:create`

## Sync server
```powershell
cd ..\server
go test ./...
go build -o openledger-server .
OPENLEDGER_ADDR=:8420 .\openledger-server.exe     # data file auto-created
# Docker: docker build -t openledger-server .
```
Hosted SaaS extras (env vars):
```
AI_UPSTREAM_URL=https://api.openai.com/v1/chat/completions
AI_UPSTREAM_KEY=sk-...
AI_UPSTREAM_MODEL=gpt-4o-mini
STRIPE_WEBHOOK_SECRET=whsec_...    # enables subscription webhooks
```

## Releases
Pushing a tag triggers the CI to build an APK artifact:
```powershell
git tag v0.3.0
git push origin v0.3.0
```

## Stripe setup (Phase 5)
1. Create a Product + Payment Link in the Stripe dashboard.
2. Point the webhook endpoint at `https://your-server/v1/stripe/webhook`,
   subscribe to `checkout.session.completed`,
   `customer.subscription.updated`, `customer.subscription.deleted`.
3. Set `STRIPE_WEBHOOK_SECRET`. When a checkout completes with a customer id
   linked to an account, the account flips to `pro` automatically.

## Hosted AI proxy (Phase 5)
Set the three `AI_*` env vars above. Apps that are paired to your server can
leave their own API key empty and route through `/v1/ai/proxy`, metered per
account (200 req/month free tier, unlimited on pro).
