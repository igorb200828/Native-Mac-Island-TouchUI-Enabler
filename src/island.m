#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#include <string.h>
#include <stdlib.h>

#define MI_LOG(fmt, ...) os_log_error(OS_LOG_DEFAULT, "Native-Mac-Island-TouchUI-Enabler: " fmt, ##__VA_ARGS__)

extern int IsAppleInternalBuild(void);

static int fake_IsAppleInternalBuild(void) {
    const char *n = getprogname();
    if (n && strcmp(n, "MenuBarAgent") == 0) return 1;
    return IsAppleInternalBuild();
}

__attribute__((used)) static struct { const void *r; const void *o; } interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)fake_IsAppleInternalBuild, (const void *)IsAppleInternalBuild },
};

typedef NSRect (*RectIMP)(id, SEL);
typedef BOOL (*BoolIMP)(id, SEL);
typedef NSUInteger (*UIntIMP)(id, SEL);
typedef void (*SetFloatIMP)(id, SEL, CGFloat);
typedef void (*SetIdIMP)(id, SEL, id);
typedef void (*SetIdIdIMP)(id, SEL, id, id);
typedef void (*SetCGRectIMP)(id, SEL, CGRect);
typedef void (*SetTransform3DIMP)(id, SEL, CATransform3D);
typedef void (*VoidIMP)(id, SEL);

static RectIMP orig_notchFrame = NULL;
static RectIMP orig_hwFrame = NULL;
static RectIMP orig_defFrame = NULL;
static RectIMP orig_minFrame = NULL;
static BoolIMP orig_isTouchScreen = NULL;
static UIntIMP orig_touchCapabilities = NULL;
static SetFloatIMP orig_setCornerRadius = NULL;
static SetCGRectIMP orig_setBounds = NULL;
static SetTransform3DIMP orig_setTransform = NULL;
static VoidIMP orig_layoutSublayers = NULL;
static SetIdIMP orig_setObsRect = NULL;
static SetIdIMP orig_setLayoutMode = NULL;
static SetIdIMP orig_addPresMod = NULL;
static SetIdIMP orig_setPresMods = NULL;
static SetIdIMP orig_modSetValue = NULL;
static SetIdIdIMP orig_modSetValueVel = NULL;

static CGFloat g_width = 250.0;
static CGFloat g_height = 40.0;
static CGFloat g_topMargin = -1.0;
static CGFloat g_expObsWidth = 60.0;
static CGFloat g_expTopOffset = 32.0;

static char kPatchedHeightKey;
static char kSceneBaseTransformKey;
static char kIslandModKey;
static char kModLastPatchedHKey;

static NSRect custom_hud_rect(id screen) {
    if (!orig_notchFrame || g_width <= 0.0) return NSZeroRect;
    NSRect notch = orig_notchFrame(screen, sel_registerName("_notchFrame"));
    if (NSIsEmptyRect(notch)) return NSZeroRect;

    CGFloat screenTop = NSMaxY(notch);
    CGFloat x = NSMidX(notch) - (g_width / 2.0);
    CGFloat y = screenTop - g_topMargin - g_height;
    return NSMakeRect(x, y, g_width, g_height);
}

static BOOL unbox_rect(id val, CGRect *outRect) {
    if (!val || ![val isKindOfClass:[NSValue class]]) return NO;
    const char *t = [(NSValue *)val objCType];
    if (!t) return NO;
    if (strcmp(t, @encode(CGRect)) != 0 && strcmp(t, @encode(NSRect)) != 0) return NO;
    [(NSValue *)val getValue:outRect];
    return YES;
}

static BOOL unbox_size(id val, CGSize *outSize) {
    if (!val || ![val isKindOfClass:[NSValue class]]) return NO;
    const char *t = [(NSValue *)val objCType];
    if (!t) return NO;
    if (strcmp(t, @encode(CGSize)) != 0 && strcmp(t, @encode(NSSize)) != 0) return NO;
    [(NSValue *)val getValue:outSize];
    return YES;
}

static CGFloat expanded_offset_for_size(CGFloat w, CGFloat h, CGFloat minW) {
    if (g_expTopOffset <= 0.0) return 0.0;
    if (w < minW || h <= 62.0 || h >= 500.0) return 0.0;
    if (h >= 84.0) return g_expTopOffset;
    return g_expTopOffset * ((h - 62.0) / 22.0);
}

static id patch_modifier_value(id mod, id val) {
    if (!val || !mod) return val;
    NSString *kp = [mod respondsToSelector:sel_registerName("keyPath")]
        ? ((id (*)(id, SEL))objc_msgSend)(mod, sel_registerName("keyPath")) : nil;
    if (!kp) return val;

    NSNumber *lastH = objc_getAssociatedObject(mod, &kModLastPatchedHKey);

    if ([kp isEqualToString:@"bounds.size"]) {
        CGSize s = CGSizeZero;
        if (unbox_size(val, &s)) {
            if (lastH && fabs(lastH.doubleValue - s.height) <= 0.5) return val;
            CGFloat off = expanded_offset_for_size(s.width, s.height, 250.0);
            if (off > 0.0) {
                s.height += off;
                objc_setAssociatedObject(mod, &kModLastPatchedHKey, @(s.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return [NSValue valueWithBytes:&s objCType:[(NSValue *)val objCType]];
            }
            objc_setAssociatedObject(mod, &kModLastPatchedHKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    } else if ([kp isEqualToString:@"bounds"]) {
        CGRect r = CGRectZero;
        if (unbox_rect(val, &r)) {
            if (lastH && fabs(lastH.doubleValue - r.size.height) <= 0.5) return val;
            CGFloat off = expanded_offset_for_size(r.size.width, r.size.height, 250.0);
            if (off > 0.0) {
                r.size.height += off;
                objc_setAssociatedObject(mod, &kModLastPatchedHKey, @(r.size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return [NSValue valueWithBytes:&r objCType:[(NSValue *)val objCType]];
            }
            objc_setAssociatedObject(mod, &kModLastPatchedHKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    }
    return val;
}

static void tag_island_modifier(CALayer *layer, id mod) {
    if (!layer || !mod) return;
    const char *cname = object_getClassName(layer);
    if (!cname || strncmp(cname, "MBGated_", 8) != 0) return;

    NSString *kp = [mod respondsToSelector:sel_registerName("keyPath")]
        ? ((id (*)(id, SEL))objc_msgSend)(mod, sel_registerName("keyPath")) : nil;
    BOOL isAdd = [mod respondsToSelector:sel_registerName("isAdditive")]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(mod, sel_registerName("isAdditive")) : NO;
    if (isAdd || !kp) return;
    if (![kp isEqualToString:@"bounds.size"] && ![kp isEqualToString:@"bounds"]) return;

    if (!objc_getAssociatedObject(mod, &kIslandModKey)) {
        objc_setAssociatedObject(mod, &kIslandModKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (orig_modSetValue && [mod respondsToSelector:sel_registerName("value")]) {
            id cur = ((id (*)(id, SEL))objc_msgSend)(mod, sel_registerName("value"));
            id patched = patch_modifier_value(mod, cur);
            if (patched != cur) {
                orig_modSetValue(mod, sel_registerName("setValue:"), patched);
            }
        }
    }
}

static id maybe_shrink_obs_value(id settings, id val) {
    CGRect r = CGRectZero;
    if (!unbox_rect(val, &r)) return val;

    id modeObj = ((id (*)(id, SEL))objc_msgSend)(settings, sel_registerName("integratedLayoutMode"));
    NSInteger mode = [modeObj isKindOfClass:[NSNumber class]] ? [(NSNumber *)modeObj integerValue] : -1;

    if (mode >= 3 && g_expObsWidth > 0.0 && r.size.width > g_expObsWidth) {
        CGRect out = r;
        CGFloat midX = CGRectGetMidX(r);
        out.origin.x = midX - (g_expObsWidth / 2.0);
        out.size.width = g_expObsWidth;
        return [NSValue valueWithBytes:&out objCType:[(NSValue *)val objCType]];
    }
    return val;
}

static BOOL install_scene_obstruction_hooks(void) {
    static BOOL installed = NO;
    if (installed) return YES;

    Class baseCls = objc_getClass("FBSSceneSettings");
    Class mutCls  = objc_getClass("FBSMutableSceneSettings");
    if (!baseCls) return NO;

    SEL sSetObs  = sel_registerName("setIntegratedObstructionRect:");
    SEL sSetMode = sel_registerName("setIntegratedLayoutMode:");

    Method mObs = class_getInstanceMethod(baseCls, sSetObs);
    if (!mObs && mutCls) mObs = class_getInstanceMethod(mutCls, sSetObs);
    if (!mObs) return NO;

    installed = YES;
    orig_setObsRect = (SetIdIMP)method_getImplementation(mObs);
    method_setImplementation(mObs, imp_implementationWithBlock(^(id self, id val) {
        orig_setObsRect(self, sSetObs, maybe_shrink_obs_value(self, val));
    }));

    Method mMode = class_getInstanceMethod(baseCls, sSetMode);
    if (!mMode && mutCls) mMode = class_getInstanceMethod(mutCls, sSetMode);
    if (mMode) {
        orig_setLayoutMode = (SetIdIMP)method_getImplementation(mMode);
        method_setImplementation(mMode, imp_implementationWithBlock(^(id self, id modeNum) {
            orig_setLayoutMode(self, sSetMode, modeNum);
            id curObs = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("integratedObstructionRect"));
            if (curObs) {
                id patched = maybe_shrink_obs_value(self, curObs);
                if (patched != curObs) {
                    orig_setObsRect(self, sSetObs, patched);
                }
            }
        }));
    }
    return YES;
}

static void retry_install_scene_hooks(int attemptsLeft) {
    if (install_scene_obstruction_hooks() || attemptsLeft <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        retry_install_scene_hooks(attemptsLeft - 1);
    });
}

static CATransform3D stored_base_transform(CALayer *layer) {
    NSValue *v = objc_getAssociatedObject(layer, &kSceneBaseTransformKey);
    if (v) return [v CATransform3DValue];
    return CATransform3DIdentity;
}

static void apply_scene_transform(CALayer *layer, CGRect b, CATransform3D baseT) {
    if (!orig_setTransform) return;
    BOOL shouldShift = (b.size.height >= 68.0 && b.size.width >= 220.0);
    CATransform3D finalT = shouldShift
        ? CATransform3DConcat(baseT, CATransform3DMakeTranslation(0.0, g_expTopOffset, 0.0))
        : baseT;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    orig_setTransform(layer, sel_registerName("setTransform:"), finalT);
    [CATransaction commit];
}

__attribute__((constructor))
static void macisland_init(void) {
    const char *n = getprogname();
    if (!n || strcmp(n, "MenuBarAgent") != 0) return;

    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.MenuBar"];
    if ([defs objectForKey:@"MacIslandWidth"])             g_width        = [defs doubleForKey:@"MacIslandWidth"];
    if ([defs objectForKey:@"MacIslandHeight"])            g_height       = [defs doubleForKey:@"MacIslandHeight"];
    if ([defs objectForKey:@"MacIslandTopMargin"])         g_topMargin    = [defs doubleForKey:@"MacIslandTopMargin"];
    if ([defs objectForKey:@"MacIslandExpandedObsWidth"])  g_expObsWidth  = [defs doubleForKey:@"MacIslandExpandedObsWidth"];
    if ([defs objectForKey:@"MacIslandExpandedTopOffset"]) g_expTopOffset = [defs doubleForKey:@"MacIslandExpandedTopOffset"];

    BOOL spoofTouch = [defs objectForKey:@"MacIslandSpoofTouchScreen"]
        ? [defs boolForKey:@"MacIslandSpoofTouchScreen"] : NO;
    BOOL flattenTopLayers = [defs objectForKey:@"MacIslandFlattenTopLayers"]
        ? [defs boolForKey:@"MacIslandFlattenTopLayers"] : YES;

    Class cls = objc_getClass("NSScreen");
    if (!cls) return;

    Method mNotch = class_getInstanceMethod(cls, sel_registerName("_notchFrame"));
    if (mNotch) orig_notchFrame = (RectIMP)method_getImplementation(mNotch);

    if (g_width > 0.0) {
        SEL sHW  = sel_registerName("_centerHUDHardwareFrame");
        SEL sDef = sel_registerName("_centerHUDDefaultFrame");
        SEL sMin = sel_registerName("_centerHUDMinimalObstructionFrame");

        Method mHW  = class_getInstanceMethod(cls, sHW);
        Method mDef = class_getInstanceMethod(cls, sDef);
        Method mMin = class_getInstanceMethod(cls, sMin);

        if (mHW) {
            orig_hwFrame = (RectIMP)method_getImplementation(mHW);
            method_setImplementation(mHW, imp_implementationWithBlock(^NSRect(id self) {
                NSRect r = custom_hud_rect(self);
                return !NSIsEmptyRect(r) ? r : orig_hwFrame(self, sHW);
            }));
        }
        if (mDef) {
            orig_defFrame = (RectIMP)method_getImplementation(mDef);
            method_setImplementation(mDef, imp_implementationWithBlock(^NSRect(id self) {
                NSRect r = custom_hud_rect(self);
                return !NSIsEmptyRect(r) ? r : orig_defFrame(self, sDef);
            }));
        }
        if (mMin) {
            orig_minFrame = (RectIMP)method_getImplementation(mMin);
            method_setImplementation(mMin, imp_implementationWithBlock(^NSRect(id self) {
                NSRect r = custom_hud_rect(self);
                return !NSIsEmptyRect(r) ? r : orig_minFrame(self, sMin);
            }));
        }
    }

    if (spoofTouch) {
        SEL sTouch = sel_registerName("_isTouchScreen");
        SEL sCaps  = sel_registerName("touchCapabilities");
        Method mTouch = class_getInstanceMethod(cls, sTouch);
        Method mCaps  = class_getInstanceMethod(cls, sCaps);

        if (mTouch) {
            orig_isTouchScreen = (BoolIMP)method_getImplementation(mTouch);
            method_setImplementation(mTouch, imp_implementationWithBlock(^BOOL(id self) {
                return !NSIsEmptyRect(orig_notchFrame ? orig_notchFrame(self, sel_registerName("_notchFrame")) : NSZeroRect)
                    ? YES : orig_isTouchScreen(self, sTouch);
            }));
        }
        if (mCaps) {
            orig_touchCapabilities = (UIntIMP)method_getImplementation(mCaps);
            method_setImplementation(mCaps, imp_implementationWithBlock(^NSUInteger(id self) {
                return !NSIsEmptyRect(orig_notchFrame ? orig_notchFrame(self, sel_registerName("_notchFrame")) : NSZeroRect)
                    ? 1 : orig_touchCapabilities(self, sCaps);
            }));
        }
    }

    Class layerCls = objc_getClass("CALayer");
    if (layerCls && flattenTopLayers) {
        SEL sSetCR = sel_registerName("setCornerRadius:");
        Method mSetCR = class_getInstanceMethod(layerCls, sSetCR);
        if (mSetCR) {
            orig_setCornerRadius = (SetFloatIMP)method_getImplementation(mSetCR);
            method_setImplementation(mSetCR, imp_implementationWithBlock(^(id self, CGFloat r) {
                orig_setCornerRadius(self, sSetCR, r);
                CALayer *layer = (CALayer *)self;
                if (r >= 12.0 && layer.bounds.size.width >= 180.0) {
                    layer.maskedCorners = layer.isGeometryFlipped
                        ? (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner)
                        : (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
                }
            }));
        }
    }

    if (layerCls && g_expTopOffset > 0.0) {
        SEL sSetT = sel_registerName("setTransform:");
        Method mSetT = class_getInstanceMethod(layerCls, sSetT);
        if (mSetT) {
            const char *enc = method_getTypeEncoding(mSetT);
            if (enc && enc[0] == 'v' && strstr(enc, "CATransform3D")) {
                orig_setTransform = (SetTransform3DIMP)method_getImplementation(mSetT);
                method_setImplementation(mSetT, imp_implementationWithBlock(^(id self, CATransform3D t) {
                    CALayer *layer = (CALayer *)self;
                    const char *cname = object_getClassName(layer);
                    if (cname && strstr(cname, "ScenePresentationLayer")) {
                        objc_setAssociatedObject(layer, &kSceneBaseTransformKey,
                                                 [NSValue valueWithCATransform3D:t],
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        CGRect b = layer.bounds;
                        if (b.size.height >= 68.0 && b.size.width >= 220.0) {
                            t = CATransform3DConcat(t, CATransform3DMakeTranslation(0.0, g_expTopOffset, 0.0));
                        }
                    }
                    orig_setTransform(self, sSetT, t);
                }));
            }
        }

        SEL sSetB = sel_registerName("setBounds:");
        Method mSetB = class_getInstanceMethod(layerCls, sSetB);
        if (mSetB) {
            orig_setBounds = (SetCGRectIMP)method_getImplementation(mSetB);
            method_setImplementation(mSetB, imp_implementationWithBlock(^(id self, CGRect b) {
                CALayer *layer = (CALayer *)self;
                const char *cname = object_getClassName(layer);

                if (cname && strstr(cname, "ScenePresentationLayer")) {
                    orig_setBounds(self, sSetB, b);
                    apply_scene_transform(layer, b, stored_base_transform(layer));
                    return;
                }

                if (cname && strncmp(cname, "MBGated_", 8) == 0) {
                    CGFloat off = expanded_offset_for_size(b.size.width, b.size.height, 250.0);
                    if (off > 0.0) {
                        NSNumber *prevPatched = objc_getAssociatedObject(layer, &kPatchedHeightKey);
                        if (!prevPatched || fabs(prevPatched.doubleValue - b.size.height) > 0.5) {
                            CGRect nb = b;
                            nb.size.height += off;
                            objc_setAssociatedObject(layer, &kPatchedHeightKey, @(nb.size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            orig_setBounds(self, sSetB, nb);
                            return;
                        }
                    } else {
                        objc_setAssociatedObject(layer, &kPatchedHeightKey, nil, OBJC_ASSOCIATION_ASSIGN);
                    }
                }

                orig_setBounds(self, sSetB, b);
            }));
        }

        SEL sLayout = sel_registerName("layoutSublayers");
        Method mLayout = class_getInstanceMethod(layerCls, sLayout);
        if (mLayout) {
            orig_layoutSublayers = (VoidIMP)method_getImplementation(mLayout);
            method_setImplementation(mLayout, imp_implementationWithBlock(^(id self) {
                orig_layoutSublayers(self, sLayout);
                CALayer *layer = (CALayer *)self;
                const char *cname = object_getClassName(layer);
                if (cname && strstr(cname, "ScenePresentationLayer")) {
                    apply_scene_transform(layer, layer.bounds, stored_base_transform(layer));
                }
            }));
        }

        Class modCls = objc_getClass("CAPresentationModifier");
        if (modCls) {
            SEL sModSetVal = sel_registerName("setValue:");
            Method mModSetVal = class_getInstanceMethod(modCls, sModSetVal);
            if (mModSetVal) {
                orig_modSetValue = (SetIdIMP)method_getImplementation(mModSetVal);
                method_setImplementation(mModSetVal, imp_implementationWithBlock(^(id self, id val) {
                    if (objc_getAssociatedObject(self, &kIslandModKey)) {
                        val = patch_modifier_value(self, val);
                    }
                    orig_modSetValue(self, sModSetVal, val);
                }));
            }

            SEL sModSetValVel = sel_registerName("setValue:velocity:");
            Method mModSetValVel = class_getInstanceMethod(modCls, sModSetValVel);
            if (mModSetValVel) {
                const char *enc = method_getTypeEncoding(mModSetValVel);
                if (enc && enc[0] == 'v') {
                    orig_modSetValueVel = (SetIdIdIMP)method_getImplementation(mModSetValVel);
                    method_setImplementation(mModSetValVel, imp_implementationWithBlock(^(id self, id val, id vel) {
                        if (objc_getAssociatedObject(self, &kIslandModKey)) {
                            val = patch_modifier_value(self, val);
                        }
                        orig_modSetValueVel(self, sModSetValVel, val, vel);
                    }));
                }
            }
        }

        SEL sAddMod = sel_registerName("addPresentationModifier:");
        Method mAddMod = class_getInstanceMethod(layerCls, sAddMod);
        if (mAddMod) {
            orig_addPresMod = (SetIdIMP)method_getImplementation(mAddMod);
            method_setImplementation(mAddMod, imp_implementationWithBlock(^(id self, id mod) {
                tag_island_modifier((CALayer *)self, mod);
                orig_addPresMod(self, sAddMod, mod);
            }));
        }

        SEL sSetMods = sel_registerName("setPresentationModifiers:");
        Method mSetMods = class_getInstanceMethod(layerCls, sSetMods);
        if (mSetMods) {
            orig_setPresMods = (SetIdIMP)method_getImplementation(mSetMods);
            method_setImplementation(mSetMods, imp_implementationWithBlock(^(id self, id mods) {
                if ([mods isKindOfClass:[NSArray class]]) {
                    for (id mod in (NSArray *)mods) {
                        tag_island_modifier((CALayer *)self, mod);
                    }
                }
                orig_setPresMods(self, sSetMods, mods);
            }));
        }
    }

    MI_LOG("Loaded | w=%.1f h=%.1f topMargin=%.1f expObsW=%.1f expOffset=%.1f spoofTouch=%d",
           g_width, g_height, g_topMargin, g_expObsWidth, g_expTopOffset, spoofTouch);

    retry_install_scene_hooks(30);
}