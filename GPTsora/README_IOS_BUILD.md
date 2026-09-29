# iOS source restoration

The application target and shared scheme are `GPT Solara`; the project is
`GPTsora.xcodeproj` and the CocoaPods workspace is `GPTsora.xcworkspace`.
Use the workspace after restoring dependencies. Local caches and `Pods/` are not
source inputs for publication and must not be committed.

## Pinned dependencies and tools

- Validation host: Xcode 26.1.1 (17B100), iOS Simulator SDK 26.1.
- CocoaPods 1.16.2; Podfile and Podfile.lock pin GoogleWebRTC 1.1.32000.
- RevenueCat purchases-ios 5.67.2, revision
  `a78d10e43fd32e636cef073b8fede9a24a0b2d0b`, used by ReceiptParser,
  RevenueCat and RevenueCatUI. Both Package.resolved files must agree.
- This preserves the project's existing GoogleWebRTC dependency. That deprecated
  distribution supports x86_64 simulator builds and does not supply an arm64
  simulator slice. The commands below explicitly select x86_64. Migrating the SDK
  is a separate change requiring API and runtime validation.

## Restore and compile without signing or launching

Run from this directory on a Mac with the stated tools. The first restoration
requires network access to the public CocoaPods CDN, Google download host and
RevenueCat GitHub repository. Do not point build directories at a production
checkout or copy private xcuserdata, credentials or signing material.

```sh
pod --version  # verify 1.16.2
pod install --deployment --no-repo-update
```

Choose a new, empty absolute directory outside this source tree for BUILD_ROOT.
Its parent must already exist. Do not reuse another build's DerivedData.

```sh
BUILD_ROOT=/absolute/existing-parent/new-gptsora-build
mkdir "$BUILD_ROOT"
xcodebuild -resolvePackageDependencies \
  -workspace GPTsora.xcworkspace -scheme 'GPT Solara' \
  -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  -disablePackageRepositoryCache -onlyUsePackageVersionsFromResolvedFile
xcodebuild build-for-testing \
  -workspace GPTsora.xcworkspace -scheme 'GPT Solara' \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
```

`build-for-testing` compiles the application and attached test bundle. It does not
run the app or its tests. The three existing Swift Testing methods are in
`GPT SolaraTests/GPT_SolaraTests.swift`, attached to the existing test target and
shared scheme. Actual simulator test execution starts the host app and therefore
is a separate, explicitly scoped runtime check.

Keep the source resources referenced by the project and retain their individual
licenses. Missing resources or unresolved redistribution rights must be recorded;
do not silently remove build inputs. Source publication and this restoration
recipe are not evidence of App Store, signing, runtime or commercial acceptance.
