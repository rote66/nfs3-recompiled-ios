#import "TouchUI.h"
#include "Native.h"
#include "ForceFeedback.h"
#include <lib/window.h>
#include <nfs3hp.h>
#include <winapi/dinput/idirectinputdevice.h>
#include <lib/renderer.h>
#include <lib/gliderenderer.h>
#include <algorithm>
#include <cmath>
#include <thread>

static BOOL hapticsEnabled = NO;
void NFSSetHapticsEnabled(BOOL enabled) { hapticsEnabled = enabled; nfsios::setHapticsEnabled(enabled); }
void NFSTouchFeedback()
{
    if (!hapticsEnabled || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    static UIImpactFeedbackGenerator* feedback;
    static CFTimeInterval lastImpact = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastImpact < 0.06) return;
    if (!feedback) feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    lastImpact = now;
}

static void segment(CGContextRef context, CGFloat startX, CGFloat startY, CGFloat endX, CGFloat endY)
{
    CGContextMoveToPoint(context, startX, startY);
    CGContextAddLineToPoint(context, endX, endY);
}

@implementation NFSSymbolButton
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
- (void)setSymbol:(NSString*)symbol { _symbol = [symbol copy]; [self setNeedsDisplay]; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self setNeedsDisplay]; }
- (void)setSelected:(BOOL)selected { [super setSelected:selected]; [self setNeedsDisplay]; }
- (void)setActive:(BOOL)active { _active = active; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect
{
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGFloat opacity = self.highlighted || self.active ? 0.95 : 0.65;
    rect = self.bounds;
    CGFloat radius = MIN(rect.size.width, rect.size.height) * 0.20;
    UIBezierPath* frame = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 1, 1) cornerRadius:radius];
    [[UIColor colorWithWhite:1 alpha:self.highlighted || self.active ? 0.24 : 0.07] setFill];
    [frame fill];
    [[UIColor colorWithWhite:1 alpha:opacity] setStroke];
    frame.lineWidth = 1.3;
    [frame stroke];
    CGContextBeginPath(context);
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat scale = MIN(rect.size.width / 58, rect.size.height / 48);
    CGContextScaleCTM(context, scale, scale);
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:opacity].CGColor);
    CGContextSetLineWidth(context, 1.6 / scale);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    NSString* symbol = self.symbol;
    if ([symbol isEqualToString:@"left"] || [symbol isEqualToString:@"right"] || [symbol isEqualToString:@"back"])
    {
        CGFloat direction = [symbol isEqualToString:@"right"] ? 1 : -1;
        segment(context, -9 * direction, 0, 9 * direction, 0);
        segment(context, 1 * direction, -8, 9 * direction, 0);
        CGContextAddLineToPoint(context, 1 * direction, 8);
    }
    else if ([symbol isEqualToString:@"accelerate"] || [symbol isEqualToString:@"brake"])
    {
        for (NSInteger row = 0; row < 4; ++row) segment(context, -13, -14 + row * 9, 13, -14 + row * 9);
    }
    else if ([symbol isEqualToString:@"gear_up"] || [symbol isEqualToString:@"gear_down"])
    {
        segment(context, -10, 0, 10, 0);
        if ([symbol isEqualToString:@"gear_up"]) segment(context, 0, -10, 0, 10);
    }
    else if ([symbol isEqualToString:@"pause"])
    {
        segment(context, -5, -10, -5, 10); segment(context, 5, -10, 5, 10);
    }
    else if ([symbol isEqualToString:@"handbrake"])
    {
        CGContextAddEllipseInRect(context, CGRectMake(-8, -8, 16, 16));
        segment(context, 0, -4, 0, 2);
        segment(context, 0, 5, 0, 5.2);
        CGContextMoveToPoint(context, 13 * cos(-0.7), 13 * sin(-0.7));
        CGContextAddArc(context, 0, 0, 13, -0.7, 0.7, false);
        CGContextMoveToPoint(context, 13 * cos(M_PI - 0.7), 13 * sin(M_PI - 0.7));
        CGContextAddArc(context, 0, 0, 13, M_PI - 0.7, M_PI + 0.7, false);
    }
    else if ([symbol isEqualToString:@"camera"])
    {
        CGContextAddRect(context, CGRectMake(-13, -7, 26, 17));
        CGContextAddEllipseInRect(context, CGRectMake(-5, -4, 10, 10));
        segment(context, -7, -7, -5, -11); CGContextAddLineToPoint(context, 5, -11); CGContextAddLineToPoint(context, 7, -7);
    }
    else if ([symbol isEqualToString:@"look_behind"])
    {
        CGContextMoveToPoint(context, -14, -6);
        CGContextAddQuadCurveToPoint(context, 0, -12, 14, -6);
        CGContextAddLineToPoint(context, 10, 7);
        CGContextAddQuadCurveToPoint(context, 0, 10, -10, 7);
        CGContextClosePath(context);
        segment(context, 0, -3, 0, 6); segment(context, -4, 2, 0, 6); CGContextAddLineToPoint(context, 4, 2);
    }
    else if ([symbol isEqualToString:@"horn"])
    {
        segment(context, -13, -4, -5, -4); CGContextAddLineToPoint(context, 3, -10); CGContextAddLineToPoint(context, 3, 10); CGContextAddLineToPoint(context, -5, 4); CGContextAddLineToPoint(context, -13, 4); CGContextClosePath(context);
        segment(context, 8, -5, 11, -8); segment(context, 9, 0, 14, 0); segment(context, 8, 5, 11, 8);
    }
    else if ([symbol isEqualToString:@"headlights"])
    {
        CGContextMoveToPoint(context, -3, -9); CGContextAddCurveToPoint(context, -19, -9, -19, 9, -3, 9); CGContextClosePath(context);
        for (NSInteger row = -1; row <= 1; ++row) segment(context, 3, row * 7, 15, row * 7 - 3);
    }
    else if ([symbol isEqualToString:@"recover"])
    {
        CGContextAddArc(context, 0, 0, 10, -M_PI / 2, M_PI, false);
        segment(context, -15, -4, -10, 0); CGContextAddLineToPoint(context, -6, -5);
    }
    else if ([symbol isEqualToString:@"spike_strip"])
    {
        segment(context, -16, 9, 16, 9);
        for (NSInteger column = -1; column <= 1; ++column)
        {
            CGFloat center = column * 10;
            segment(context, center - 4, 5, center, -8); CGContextAddLineToPoint(context, center + 4, 5);
        }
    }
    else if ([symbol isEqualToString:@"keyboard"])
    {
        CGContextAddRect(context, CGRectMake(-15, -9, 30, 18));
        for (NSInteger row = 0; row < 2; ++row)
            for (NSInteger column = 0; column < 5; ++column) segment(context, -10 + column * 5, -4 + row * 5, -9 + column * 5, -4 + row * 5);
        segment(context, -7, 6, 7, 6);
    }
    else if ([symbol isEqualToString:@"visibility"])
    {
        CGContextMoveToPoint(context, -17, 0);
        CGContextAddCurveToPoint(context, -7, -14, 7, -14, 17, 0);
        CGContextAddCurveToPoint(context, 7, 14, -7, 14, -17, 0);
        CGContextClosePath(context);
        CGContextAddEllipseInRect(context, CGRectMake(-5, -5, 10, 10));
        if (!self.active) segment(context, -17, -14, 17, 14);
    }
    else if ([symbol isEqualToString:@"tilt"])
    {
        CGContextSaveGState(context);
        CGContextRotateCTM(context, -M_PI / 8);
        CGContextAddPath(context, [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-8, -13, 16, 26) cornerRadius:3].CGPath);
        segment(context, -2, 8, 2, 8);
        CGContextStrokePath(context);
        CGContextRestoreGState(context);
        CGContextMoveToPoint(context, -19, 3);
        CGContextAddQuadCurveToPoint(context, -21, -8, -12, -14);
        segment(context, -18, -14, -12, -14); CGContextAddLineToPoint(context, -13, -8);
        CGContextMoveToPoint(context, 19, -3);
        CGContextAddQuadCurveToPoint(context, 21, 8, 12, 14);
        segment(context, 18, 14, 12, 14); CGContextAddLineToPoint(context, 13, 8);
    }
    else if ([symbol isEqualToString:@"done"])
    {
        segment(context, -10, 0, -3, 7); CGContextAddLineToPoint(context, 11, -8);
    }
    CGContextStrokePath(context);
    CGContextRestoreGState(context);
    if (self.selected)
    {
        UIBezierPath* selection = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 3, 3) cornerRadius:MAX(1, radius - 2)];
        CGFloat pattern[] = {4, 4};
        [selection setLineDash:pattern count:2 phase:0];
        selection.lineWidth = 2;
        [[UIColor colorWithRed:1 green:0.75 blue:0.42 alpha:1] setStroke];
        [selection stroke];
    }
}
@end

@implementation NFSControlSurface
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    if (self.hidden || !self.userInteractionEnabled || self.alpha <= 0.01 || ![self pointInside:point withEvent:event]) return nil;
    UIView* nearest = nil;
    CGFloat distance = CGFLOAT_MAX;
    for (UIView* candidate in self.subviews)
    {
        if (candidate.hidden || !candidate.userInteractionEnabled || candidate.alpha <= 0.01) continue;
        CGPoint local = [candidate convertPoint:point fromView:self];
        if (![candidate pointInside:local withEvent:event]) continue;
        CGFloat horizontal = (local.x - CGRectGetMidX(candidate.bounds)) / MAX(1, candidate.bounds.size.width);
        CGFloat vertical = (local.y - CGRectGetMidY(candidate.bounds)) / MAX(1, candidate.bounds.size.height);
        CGFloat score = horizontal * horizontal + vertical * vertical;
        if (score < distance) { distance = score; nearest = candidate; }
    }
    return nearest ? [nearest hitTest:[nearest convertPoint:point fromView:self] withEvent:event] : nil;
}
@end

@interface NFSKeyboardField : UITextField
@property(nonatomic, weak) NFSGameInputView* bridge;
@end
@implementation NFSKeyboardField
- (void)deleteBackward { [self.bridge deleteBackward]; }
@end

@implementation NFSGameInputView
{
    NFSKeyboardField* _keyboard;
    UITouch* _contact;
    CGPoint _origin;
    CGPoint _latest;
    NSUInteger _generation;
    BOOL _wandered;
    BOOL _pressed;
    NSUInteger _trace;
    NSMutableSet<UITouch*>* _brakeTouches;
}
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        _brakeTouches = [NSMutableSet set];
        _keyboard = [[NFSKeyboardField alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        _keyboard.bridge = self;
        _keyboard.delegate = self;
        _keyboard.text = @" ";
        _keyboard.textColor = UIColor.clearColor;
        _keyboard.tintColor = UIColor.clearColor;
        _keyboard.alpha = 0.01;
        _keyboard.accessibilityElementsHidden = YES;
        _keyboard.keyboardType = UIKeyboardTypeASCIICapable;
        _keyboard.autocorrectionType = UITextAutocorrectionTypeNo;
        _keyboard.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _keyboard.spellCheckingType = UITextSpellCheckingTypeNo;
        _keyboard.returnKeyType = UIReturnKeyDone;
        [self addSubview:_keyboard];
    }
    return self;
}
- (BOOL)becomeFirstResponder { return [_keyboard becomeFirstResponder]; }
- (BOOL)resignFirstResponder { return [_keyboard resignFirstResponder]; }
- (BOOL)isFirstResponder { return _keyboard.isFirstResponder; }
- (BOOL)textField:(UITextField*)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)text
{
    (void)field; (void)range;
    if (text.length) [self insertText:text];
    else [self deleteBackward];
    return NO;
}
- (BOOL)textFieldShouldReturn:(UITextField*)field { (void)field; [self insertText:@"\n"]; return NO; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeASCIICapable; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }
- (UIReturnKeyType)returnKeyType { return UIReturnKeyDone; }
- (void)insertText:(NSString*)text
{
    if (!self.enabled) return;
    NSData* bytes = [text dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:NO];
    for (NSUInteger index = 0; index < bytes.length; ++index)
    {
        uint8_t value = static_cast<const uint8_t*>(bytes.bytes)[index];
        if (value == '\n' || value == '\r')
        {
            nfsios::key(13, true); nfsios::key(13, false);
            if (!nfsios::takingText()) [self resignFirstResponder];
        }
        else nfsios::character(value);
    }
}
- (void)deleteBackward { if (self.enabled) { nfsios::key(8, true); nfsios::key(8, false); } }
- (CGRect)pictureRect
{
    double width, height;
    nfsios::presentationSize(width, height);
    double scale = MIN(self.bounds.size.width / width, self.bounds.size.height / height);
    return CGRectMake((self.bounds.size.width - width * scale) / 2, (self.bounds.size.height - height * scale) / 2, width * scale, height * scale);
}
- (void)sendPointer:(CGPoint)point button:(int)button
{
    CGRect rect = [self pictureRect];
    if (rect.size.width > 0 && rect.size.height > 0)
        nfsios::pointer((point.x - rect.origin.x) / rect.size.width, (point.y - rect.origin.y) / rect.size.height, button);
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (self.enabled && self.brakeEnabled)
    {
        [_brakeTouches unionSet:touches];
        NFSTouchFeedback();
        return;
    }
    (void)event;
    if (_trace++ < 40)
        win32::platform::log("NFS3_TOUCH_UI: begin enabled=%d race=%d contacts=%lu picture=%s", self.enabled, nfsios::inRace(), (unsigned long)touches.count, NSStringFromCGRect([self pictureRect]).UTF8String);
    if (!self.enabled || nfsios::inRace() || _contact) return;
    UITouch* contact = touches.anyObject;
    CGPoint point = [contact locationInView:self];
    if (!CGRectContainsPoint([self pictureRect], point)) return;
    _contact = contact; _origin = _latest = point; _wandered = _pressed = NO;
    [self sendPointer:point button:-1];
    NSUInteger generation = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (generation == self->_generation) [self holdPointer];
    });
}
- (void)holdPointer
{
    if (!_contact || _pressed || _wandered) return;
    _pressed = YES;
    [self sendPointer:_latest button:1];
    NFSTouchFeedback();
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    (void)event;
    if (!_contact || ![touches containsObject:_contact]) return;
    _latest = [_contact locationInView:self];
    if (!_pressed && hypot(_latest.x - _origin.x, _latest.y - _origin.y) > 8) _wandered = YES;
    [self sendPointer:_latest button:-1];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (self.brakeEnabled)
    {
        [_brakeTouches minusSet:touches];
        return;
    }
    (void)event;
    if (!_contact || ![touches containsObject:_contact]) return;
    _latest = [_contact locationInView:self];
    if (!_pressed && hypot(_latest.x - _origin.x, _latest.y - _origin.y) > 8) _wandered = YES;
    if (_pressed) [self sendPointer:_latest button:0];
    else if (!_wandered) { [self sendPointer:_latest button:1]; [self sendPointer:_latest button:0]; }
    _contact = nil; ++_generation; _pressed = NO;
}
- (void)cancelPointer
{
    [_brakeTouches removeAllObjects];
    if (_pressed) [self sendPointer:_latest button:0];
    _contact = nil; ++_generation; _pressed = NO;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (self.brakeEnabled) [_brakeTouches minusSet:touches];
    else [self cancelPointer];
    (void)event;
}
- (BOOL)braking { return _brakeTouches.count > 0; }
- (void)setBrakeEnabled:(BOOL)enabled
{
    if (_brakeEnabled == enabled) return;
    [self cancelPointer];
    _brakeEnabled = enabled;
}
@end

@interface NFSFixtureTouch : UITouch
@property(nonatomic) CGPoint point;
@end
@implementation NFSFixtureTouch
- (CGPoint)locationInView:(UIView*)view { (void)view; return self.point; }
@end

void NFSBrakeDiagnostic()
{
    NFSGameInputView* view = [[NFSGameInputView alloc] initWithFrame:CGRectMake(0, 0, 640, 480)];
    view.enabled = YES; view.brakeEnabled = YES;
    UITouch* first = [NFSFixtureTouch new];
    UITouch* second = [NFSFixtureTouch new];
    [view touchesBegan:[NSSet setWithObject:first] withEvent:nil];
    [view touchesBegan:[NSSet setWithObject:second] withEvent:nil];
    NFS2_ASSERT(view.braking);
    [view touchesEnded:[NSSet setWithObject:first] withEvent:nil];
    NFS2_ASSERT(view.braking);
    [view touchesCancelled:[NSSet setWithObject:second] withEvent:nil];
    NFS2_ASSERT(!view.braking);
    [view touchesBegan:[NSSet setWithObject:first] withEvent:nil];
    view.brakeEnabled = NO;
    NFS2_ASSERT(!view.braking);
    view.brakeEnabled = YES;
    [view touchesBegan:[NSSet setWithObject:second] withEvent:nil];
    [view cancelPointer];
    NFS2_ASSERT(!view.braking);
}

void NFSPointerDiagnostic()
{
    nfsios::setRaceActive(false);
    UIView* root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1024, 600)];
    NFSGameInputView* view = [[NFSGameInputView alloc] initWithFrame:root.bounds];
    view.enabled = YES;
    [root addSubview:view];
    NFSControlSurface* surface = [[NFSControlSurface alloc] initWithFrame:root.bounds];
    [root addSubview:surface];
    NFSSymbolButton* button = [[NFSSymbolButton alloc] initWithFrame:CGRectMake(0, 0, 58, 48)];
    [surface addSubview:button];
    NFS2_ASSERT([root hitTest:CGPointMake(312, 150) withEvent:nil] == view);
    NFS2_ASSERT([root hitTest:CGPointMake(20, 20) withEvent:nil] == button);
    NFSSymbolButton* overlap = [[NFSSymbolButton alloc] initWithFrame:CGRectMake(20, 0, 58, 48)];
    [surface addSubview:overlap];
    NFS2_ASSERT([root hitTest:CGPointMake(20, 20) withEvent:nil] == button);
    NFS2_ASSERT([root hitTest:CGPointMake(48, 20) withEvent:nil] == overlap);
    nfs3hp::Application game("nfs3.exe");
    win32::Renderer renderer(&game, nullptr);
    renderer.setVideoMode(640, 480, 16);
    win32::GlideRenderer glide(&renderer);
    glide.clear(0x080c14);
    x86::CPU initialization{};
    NFS2_ASSERT(game.runThread(initialization, 0x4350a0) == 1);
    NFS2_ASSERT(game.getMemory<uint32_t>(0x554ee8) != 0);
    win32::platform::log("NFS3_MOUSE_INIT_DIAGNOSTIC: original initialization returned mouse=%x bounds=%d,%d..%d,%d",
        unsigned(game.getMemory<uint32_t>(0x554ee8)), int(game.getMemory<int32_t>(0x5f38e0)), int(game.getMemory<int32_t>(0x5f38e4)),
        int(game.getMemory<int32_t>(0x5f38e8)), int(game.getMemory<int32_t>(0x5f38ec)));
    game.registerMethod(0x400ffc, {"MouseCapabilitiesDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
        uint32_t device = app->getMemory<uint32_t>(0x554ee8);
        app->getMemory<uint32_t>(0x5f3960) = 44;
        cpu.esp -= 12;
        app->getMemory<uint32_t>(cpu.esp + 4) = device;
        app->getMemory<uint32_t>(cpu.esp + 8) = 0x5f3960;
        app->dynamic_call(app->getMemory<uint32_t>(app->getMemory<uint32_t>(device) + 12), cpu);
        cpu.esp += 4;
    }});
    game.registerMethod(0x400ffd, {"MouseStateDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
        uint32_t device = app->getMemory<uint32_t>(0x554ee8);
        cpu.esp -= 16;
        app->getMemory<uint32_t>(cpu.esp + 4) = device;
        app->getMemory<uint32_t>(cpu.esp + 8) = 16;
        app->getMemory<uint32_t>(cpu.esp + 12) = 0x5f3920;
        app->dynamic_call(app->getMemory<uint32_t>(app->getMemory<uint32_t>(device) + 36), cpu);
        cpu.esp += 4;
    }});
    x86::CPU capabilities{};
    NFS2_ASSERT(game.runThread(capabilities, 0x400ffc) == 0);
    NFS2_ASSERT(game.getMemory<uint32_t>(0x5f3968) == 2 && game.getMemory<uint32_t>(0x5f396c) == 3 && game.getMemory<uint32_t>(0x5f3970) == 4);
    game.getMemory<uint32_t>(0x56446c) = 0;
    game.registerMethod(0x400ffe, {"PointerGuestDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
        cpu.eax = 0; cpu.edx = 0; cpu.ebx = 0; cpu.ecx = 0;
        cpu.esp -= 4;
        app->dynamic_call(0x435310, cpu);
        cpu.esp += 4;
    }});
    auto poll = [&] { x86::CPU cpu{}; game.runThread(cpu, 0x400ffe); };
    auto frame = [&] { glide.swap(); NFS2_ASSERT(!nfsios::inRace()); };
    auto state = [&] { x86::CPU cpu{}; NFS2_ASSERT(game.runThread(cpu, 0x400ffd) == 0); };
    NFSFixtureTouch* contact = [NFSFixtureTouch new];
    contact.point = CGPointMake(312, 150);
    NSSet* touches = [NSSet setWithObject:contact];
    [view touchesBegan:touches withEvent:nil];
    [view touchesEnded:touches withEvent:nil];
    win32::MSG message{};
    x86::CPU cpu{};
    for (unsigned expected : {0x200, 0x201, 0x202})
    {
        auto received = win32::Window::getMessage(cpu, &message, nullptr, 0, 0);
        win32::platform::log("NFS3_TOUCH_DIAGNOSTIC_MESSAGE: expected=%x received=%x result=%u", expected, unsigned(message.message), unsigned(received));
        NFS2_ASSERT(received == 1 && message.message == expected);
    }
    frame(); poll();
    NFS2_ASSERT(game.getMemory<int32_t>(0x5f38f0) == 160 && game.getMemory<int32_t>(0x5f38f4) == 120);
    NFS2_ASSERT((game.getMemory<uint32_t>(0x5f38f8) & 0x101) == 1);
    state();
    NFS2_ASSERT(game.getMemory<uint8_t>(0x5f392c) == 0x80);
    state();
    NFS2_ASSERT(game.getMemory<int32_t>(0x5f3920) == 0 && game.getMemory<int32_t>(0x5f3924) == 0 && game.getMemory<uint8_t>(0x5f392c) == 0x80);
    poll();
    NFS2_ASSERT((game.getMemory<uint32_t>(0x5f38f8) & 0x101) == 1);
    frame(); poll();
    NFS2_ASSERT((game.getMemory<uint32_t>(0x5f38f8) & 0x101) == 0x100);
    state(); NFS2_ASSERT(game.getMemory<uint8_t>(0x5f392c) == 0);
    contact.point = CGPointMake(512, 300);
    [view touchesBegan:touches withEvent:nil]; [view holdPointer]; frame(); poll();
    contact.point = CGPointMake(712, 450);
    [view touchesMoved:touches withEvent:nil]; frame(); poll();
    NFS2_ASSERT(game.getMemory<int32_t>(0x5f38f0) == 480 && game.getMemory<int32_t>(0x5f38f4) == 360);
    NFS2_ASSERT((game.getMemory<uint32_t>(0x5f38f8) & 1) == 1);
    [view touchesCancelled:touches withEvent:nil];
    frame(); poll();
    NFS2_ASSERT((game.getMemory<uint32_t>(0x5f38f8) & 0x101) == 0x100);
    for (unsigned expected : {0x200, 0x201, 0x200, 0x202})
        NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == expected);
    contact.point = CGPointMake(312, 150);
    [view touchesBegan:touches withEvent:nil];
    contact.point = CGPointMake(712, 450);
    [view touchesMoved:touches withEvent:nil]; [view holdPointer];
    [view touchesEnded:touches withEvent:nil]; frame(); poll();
    NFS2_ASSERT(game.getMemory<int32_t>(0x5f38f0) == 480 && game.getMemory<int32_t>(0x5f38f4) == 360 && !(game.getMemory<uint32_t>(0x5f38f8) & 0x101));
    NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == 0x200);
    contact.point = CGPointMake(10, 300);
    [view touchesBegan:touches withEvent:nil]; [view touchesEnded:touches withEvent:nil]; poll();
    NFS2_ASSERT(game.getMemory<int32_t>(0x5f38f0) == 480 && !(game.getMemory<uint32_t>(0x5f38f8) & 0x101));
    win32::platform::log("NFS3_TOUCH_GUEST_DIAGNOSTIC: PASS Glide menus accept pointer input; original EXE mouse initialization/capabilities, buffered and immediate state, hit testing, aspect-fit coordinates, tap/hold/drag/cancel/swipe and separate frame press/release");
}

void NFSKeyboardDiagnostic()
{
    NFSGameInputView* view = [[NFSGameInputView alloc] initWithFrame:CGRectMake(0, 0, 640, 480)];
    view.enabled = YES;
    UITextField* field = (UITextField*)view.subviews.firstObject;
    NFS2_ASSERT([field isKindOfClass:UITextField.class]);
    NFS2_ASSERT(![view textField:field shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:@"N3"]);
    [field deleteBackward];
    NFS2_ASSERT(![view textFieldShouldReturn:field]);
    NFS2_ASSERT([field.text isEqualToString:@" "]);
    x86::CPU cpu{};
    win32::MSG message{};
    const unsigned expectedMessages[] = {0x102,0x102,0x100,0x102,0x101,0x100,0x102,0x101};
    const unsigned expectedValues[] = {'N','3',8,8,8,13,13,13};
    for (unsigned index = 0; index < 8; ++index)
        NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == expectedMessages[index] && message.wParam == expectedValues[index]);
    win32::platform::log("NFS3_KEYBOARD_DIAGNOSTIC: PASS UIKit text field bridge, deletion and Return reach the guest without hidden text accumulation");
}

NSArray<NSValue*>* NFSDefaultControlFrames(CGRect area, CGFloat pixel, CGFloat header)
{
    double scale = NFSControlLayoutScale(area.size, header);
    double width = area.size.width / scale, height = area.size.height / scale;
    double physical = pixel / scale;
    auto snap = [](double value) { return std::round(value / 8) * 8; };
    double column = 64, row = 56, top = 40;
    NSMutableArray<NSValue*>* frames = [NSMutableArray arrayWithCapacity:14];
    for (unsigned index = 0; index < 14; ++index) [frames addObject:[NSValue valueWithCGRect:CGRectZero]];
    auto place = [&](unsigned index, double centerX, double centerY, double controlWidth, double controlHeight) {
        CGRect frame = CGRectMake(area.origin.x + (centerX - controlWidth / 2) * scale, area.origin.y + (centerY - controlHeight / 2) * scale, controlWidth * scale, controlHeight * scale);
        frames[index] = [NSValue valueWithCGRect:frame];
    };
    const unsigned leftColumn[] = {5,12,9,6,7};
    const unsigned rightColumn[] = {10,13,11,8,4};
    for (unsigned index = 0; index < 5; ++index)
    {
        place(leftColumn[index], snap(29), (index == 0 ? 28 : top + index * row + (index >= 3 ? 8 : 0)) + header / scale, 58, 48);
        place(rightColumn[index], snap(width - 39), top + index * row, 58, 48);
    }
    double steerY = snap(height - 58);
    bool tightSteering = top + header / scale + 4 * row + 36 > steerY - 38;
    double steerX = snap(54 + (tightSteering ? column : 0));
    double steerStep = std::ceil((76 + 26 * physical) / 8) * 8 - (tightSteering ? 16 : 0);
    place(0, steerX, steerY, 64, 64); place(1, steerX + steerStep, steerY, 64, 64);
    double brakeY = snap(height - 62);
    bool tightPedals = top + 4 * row + 28 > brakeY - 42;
    double brakeX = snap(width - 51 - 5 * physical - (tightPedals ? column : 0));
    double gasWidth = 64;
    double gasX = brakeX - 31 - (12 + 19 * physical) - gasWidth / 2;
    place(3, brakeX, brakeY, 64, 64); place(2, gasX, brakeY - 8, gasWidth, 80);
    return frames;
}

CGFloat NFSControlLayoutScale(CGSize size, CGFloat header)
{
    return MAX(0.001, MIN(1, MIN(size.width / 640, (size.height - header) / 340)));
}
CGRect NFSConstrainControlFrame(CGRect frame, CGRect area)
{
    CGFloat width = MIN(frame.size.width, area.size.width), height = MIN(frame.size.height, area.size.height);
    CGFloat horizontal = MIN(MAX(CGRectGetMidX(frame), CGRectGetMinX(area) + width / 2), CGRectGetMaxX(area) - width / 2);
    CGFloat vertical = MIN(MAX(CGRectGetMidY(frame), CGRectGetMinY(area) + height / 2), CGRectGetMaxY(area) - height / 2);
    return CGRectMake(horizontal - width / 2, vertical - height / 2, width, height);
}
CGRect NFSResolveControlFrame(CGRect base, CGRect area, CGFloat scale, NSArray* values)
{
    if (values.count < 3) return NFSConstrainControlFrame(base, area);
    CGFloat size = MIN(1.8, MAX(0.5, [values[2] doubleValue]));
    CGFloat horizontal, vertical;
    if (values.count >= 5)
    {
        horizontal = [values[3] boolValue] ? CGRectGetMaxX(area) - [values[0] doubleValue] * scale : area.origin.x + [values[0] doubleValue] * scale;
        vertical = [values[4] boolValue] ? CGRectGetMaxY(area) - [values[1] doubleValue] * scale : area.origin.y + [values[1] doubleValue] * scale;
    }
    else
    {
        horizontal = area.origin.x + area.size.width * [values[0] doubleValue];
        vertical = area.origin.y + area.size.height * [values[1] doubleValue];
    }
    return NFSConstrainControlFrame(CGRectMake(horizontal - base.size.width * size / 2, vertical - base.size.height * size / 2, base.size.width * size, base.size.height * size), area);
}
NSArray* NFSEncodeControlFrame(CGRect frame, CGRect area, CGFloat scale, CGFloat size)
{
    frame = NFSConstrainControlFrame(frame, area);
    BOOL right = CGRectGetMidX(frame) > CGRectGetMidX(area), bottom = CGRectGetMidY(frame) > CGRectGetMidY(area);
    CGFloat horizontal = right ? CGRectGetMaxX(area) - CGRectGetMidX(frame) : CGRectGetMidX(frame) - area.origin.x;
    CGFloat vertical = bottom ? CGRectGetMaxY(area) - CGRectGetMidY(frame) : CGRectGetMidY(frame) - area.origin.y;
    return @[@(horizontal / scale), @(vertical / scale), @(MIN(1.8, MAX(0.5, size))), @(right), @(bottom)];
}
