#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef double (*MenuHeightIMP)(id, SEL, bool);
typedef void (*SetBoolIMP)(id, SEL, bool);

static MenuHeightIMP orig_prefMenuHeight = NULL;
static SetBoolIMP orig_setDirectGestureSpacing = NULL;

static bool should_skip_process(void) {
    const char *prog = getprogname();
    if (prog && (strcmp(prog, "MenuBarAgent") == 0 ||
                 strcmp(prog, "chronod") == 0)) {
        return true;
    }

    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        if (strstr(path, ".appex/") != NULL) {
            return true; // Skip WidgetKit / Live Activity extensions
        }
    }
    return false;
}

static void hook_bool_getter(const char *clsName, const char *selName, bool isClassMethod) {
    Class cls = objc_getClass(clsName);
    if (!cls) return;
    SEL s = sel_registerName(selName);
    Method m = isClassMethod ? class_getClassMethod(cls, s) : class_getInstanceMethod(cls, s);
    if (!m) return;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || (enc[0] != 'B' && enc[0] != 'c')) return;
    method_setImplementation(m, imp_implementationWithBlock(^bool(id self) {
        return true;
    }));
}

__attribute__((constructor))
static void touchui_init(void) {
    if (should_skip_process()) return;

    Class screenCls = objc_getClass("NSScreen");
    if (!screenCls) return; // Exit immediately in non-GUI background daemons

    hook_bool_getter("NSScreen", "_isTouchScreen", false);
    hook_bool_getter("NSEvent", "_lastInteractionWasDirectTouch", true);

    Method mCaps = class_getInstanceMethod(screenCls, sel_registerName("touchCapabilities"));
    if (mCaps) {
        method_setImplementation(mCaps, imp_implementationWithBlock(^unsigned long(id self) {
            return 1;
        }));
    }

    hook_bool_getter("NSCocoaMenuImpl", "isDirectGestureSpacing", false);
    hook_bool_getter("NSContextMenuImpl", "isDirectGestureSpacing", false);
    hook_bool_getter("NSMenuTrackingSession", "isDirectGestureSpacing", false);
    hook_bool_getter("NSMenuBarTrackingSession", "forceNextSessionToDirectGestureSpacing", true);

    Class cocoaMenuCls = objc_getClass("NSCocoaMenuImpl");
    if (cocoaMenuCls) {
        SEL sSetDGS = sel_registerName("setIsDirectGestureSpacing:");
        Method mSetDGS = class_getInstanceMethod(cocoaMenuCls, sSetDGS);
        if (mSetDGS) {
            const char *enc = method_getTypeEncoding(mSetDGS);
            if (enc && enc[0] == 'v') {
                orig_setDirectGestureSpacing = (SetBoolIMP)method_getImplementation(mSetDGS);
                method_setImplementation(mSetDGS, imp_implementationWithBlock(^(id self, bool val) {
                    orig_setDirectGestureSpacing(self, sSetDGS, true);
                }));
            }
        }
    }

    Class menuCls = objc_getClass("NSMenu");
    if (menuCls) {
        SEL sHeight = sel_registerName("_preferredItemHeightForDirectTouch:");
        Method mHeight = class_getClassMethod(menuCls, sHeight);
        if (mHeight) {
            const char *enc = method_getTypeEncoding(mHeight);
            if (enc && enc[0] == 'd') {
                orig_prefMenuHeight = (MenuHeightIMP)method_getImplementation(mHeight);
                method_setImplementation(mHeight, imp_implementationWithBlock(^double(id self, bool isDirect) {
                    return orig_prefMenuHeight(self, sHeight, true);
                }));
            }
        }
    }
}