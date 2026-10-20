# Mesh Pulse build targets. Requires Godot 4.7 on PATH (override with GODOT=...) and its export templates.
#
#   make macos | windows | linux | web | android   build one platform into build/<platform>/
#   make all                                         build everything
#   make android-release                             signed release APK; needs the GODOT_ANDROID_KEYSTORE_RELEASE_* env vars
#   make install-android                             build and install the debug APK on a connected device
#   make serve-web                                   serve build/web on http://localhost:8060
#   make test                                        headless unit tests
#   make web-sync                                    build web, upload to S3 and invalidate CloudFront
#
# Desktop and web builds are release exports; set MODE=debug for debug builds.

GODOT ?= godot
MODE  ?= release
BUILD := build

AWS_PROFILE ?= aclaghorn-beacon
STACK       := MeshPulseWeb
AWS         := aws --profile $(AWS_PROFILE) --region us-east-1

EXPORT = $(GODOT) --headless --path . --export-$(MODE)

.PHONY: all macos windows linux web android android-release install-android serve-web web-sync test import clean

all: macos windows linux web android

# Make sure the import cache (.godot/) exists, e.g. on a fresh checkout.
# Also keeps Godot from importing build output, which lives inside the project folder.
import:
	@mkdir -p $(BUILD) && touch $(BUILD)/.gdignore
	@test -d .godot/imported || $(GODOT) --headless --path . --import

macos: import
	@mkdir -p $(BUILD)/macos
	$(EXPORT) "macOS" $(BUILD)/macos/MeshPulse.zip

windows: import
	@mkdir -p $(BUILD)/windows
	$(EXPORT) "Windows" $(BUILD)/windows/MeshPulse.exe

linux: import
	@mkdir -p $(BUILD)/linux
	$(EXPORT) "Linux" $(BUILD)/linux/MeshPulse.x86_64

web: import
	@mkdir -p $(BUILD)/web
	$(EXPORT) "Web" $(BUILD)/web/index.html

# Debug-signed with the editor's debug keystore, so it installs without extra setup.
android: import
	@mkdir -p $(BUILD)/android
	$(GODOT) --headless --path . --export-debug "Android" $(BUILD)/android/MeshPulse.apk

android-release: import
	@test -n "$$GODOT_ANDROID_KEYSTORE_RELEASE_PATH" || (echo "Set GODOT_ANDROID_KEYSTORE_RELEASE_PATH, _USER and _PASSWORD" && exit 1)
	@mkdir -p $(BUILD)/android
	$(GODOT) --headless --path . --export-release "Android" $(BUILD)/android/MeshPulse-release.apk

install-android: android
	adb install -r $(BUILD)/android/MeshPulse.apk

serve-web: web
	cd $(BUILD)/web && python3 -m http.server 8060

# Export file names never change, so browsers are told to revalidate every time (cheap 304s via
# ETag); CloudFront keeps edge copies until the invalidation below.
web-sync: web
	@set -e; \
	output() { $(AWS) cloudformation describe-stacks --stack-name $(STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='$$1'].OutputValue" --output text; }; \
	bucket=$$(output BucketName); dist=$$(output DistributionId); \
	test -n "$$bucket" -a -n "$$dist" || { echo "CloudFormation stack $(STACK) not found"; exit 1; }; \
	echo "Uploading $(BUILD)/web to s3://$$bucket"; \
	$(AWS) s3 sync $(BUILD)/web s3://$$bucket --delete --only-show-errors --exclude "*.wasm" \
		--cache-control "public, max-age=0, must-revalidate"; \
	$(AWS) s3 cp $(BUILD)/web s3://$$bucket --recursive --only-show-errors --exclude "*" --include "*.wasm" \
		--content-type application/wasm --cache-control "public, max-age=0, must-revalidate"; \
	echo "Invalidating CloudFront $$dist"; \
	$(AWS) cloudfront create-invalidation --distribution-id $$dist --paths "/*" \
		--query "Invalidation.[Id,Status]" --output text

test:
	$(GODOT) --headless --path . -s tests/run_tests.gd

clean:
	rm -rf $(BUILD)
