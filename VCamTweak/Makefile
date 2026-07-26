TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamTweak

VCamTweak_FILES = Tweak.x
VCamTweak_CFLAGS = -fobjc-arc
VCamTweak_FRAMEWORKS = AVFoundation CoreMedia CoreVideo

include $(THEOS_MAKE_PATH)/tweak.mk
