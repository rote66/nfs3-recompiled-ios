#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach/mach.h>
#include <thread>
#include <condition_variable>
#include <cmath>
#include <algorithm>
#include "Native.h"
#include "ForceFeedback.h"
#import "TouchUI.h"
#import "LayoutEditor.h"
#include <lib/file.h>
#include <lib/window.h>
#include <nfs3hp.h>

static NSString* documentsPath()
{
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
static NSString* dataPath() { return [documentsPath() stringByAppendingPathComponent:@"data"]; }
static NSString* logPath() { return [documentsPath() stringByAppendingPathComponent:@"log"]; }
static BOOL directoryContainsGame(NSString* path)
{
    NSArray<NSString*>* names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    BOOL data = NO, front = NO;
    for (NSString* name in names)
    {
        NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[path stringByAppendingPathComponent:name] error:nil];
        BOOL directory = [attributes[NSFileType] isEqualToString:NSFileTypeDirectory];
        if (directory && [name.lowercaseString isEqualToString:@"gamedata"]) data = YES;
        if (directory && [name.lowercaseString isEqualToString:@"fedata"]) front = YES;
    }
    return data && front;
}
static NSString* gamePath()
{
    return dataPath();
}
static NSString* caseMatchedPath(NSString* root, NSString* relative)
{
    NSString* path = root;
    for (NSString* component in relative.pathComponents)
    {
        if ([component isEqualToString:@"."]) continue;
        NSString* actual = component;
        for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil])
            if ([name caseInsensitiveCompare:component] == NSOrderedSame) { actual = name; break; }
        path = [path stringByAppendingPathComponent:actual];
    }
    return path;
}
static BOOL prepareGameDirectory(NSString* root, NSError** failure)
{
    NSFileManager* manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:failure]) return NO;
    for (NSString* name in @[@"nfs3.exe", @"eacsnd.dll", @"softtria.dll", @"voodoo2a.dll", @"install.win"])
    {
        NSString* target = caseMatchedPath(root, name);
        if ([manager fileExistsAtPath:target]) continue;
        NSString* source = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[@"GameFiles" stringByAppendingPathComponent:name]];
        if (![manager copyItemAtPath:source toPath:target error:failure]) return NO;
    }
    if (directoryContainsGame(root))
        for (NSString* folder in @[@"fedata/save", @"fedata/stats", @"fedata/config"])
            if (![manager createDirectoryAtPath:caseMatchedPath(root, folder) withIntermediateDirectories:YES attributes:nil error:failure]) return NO;
    return YES;
}
static UIButton* actionButton(NSString* title, id target, SEL action)
{
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    button.tintColor = UIColor.whiteColor;
    button.layer.cornerRadius = 10;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    return button;
}

@interface NFSKeyButton : NFSSymbolButton
@property(nonatomic) unsigned virtualKey;
@property(nonatomic) BOOL pulse;
@property(nonatomic) NSUInteger pressGeneration;
- (void)cancelPress;
@end
@implementation NFSKeyButton
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
        [self addTarget:self action:@selector(press) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [self addTarget:self action:@selector(releaseKey) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
        self.accessibilityIdentifier = @"touch-control";
    }
    return self;
}
- (void)press
{
    if (self.hidden || self.superview.hidden) return;
    NFSTouchFeedback();
    nfsios::key(self.virtualKey, true);
    if (self.pulse)
    {
        NSUInteger generation = ++self.pressGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (generation == self.pressGeneration) nfsios::key(self.virtualKey, false);
        });
    }
}
- (void)releaseKey { if (!self.pulse) nfsios::key(self.virtualKey, false); }
- (void)cancelPress
{
    [self cancelTrackingWithEvent:nil];
    ++self.pressGeneration;
    nfsios::key(self.virtualKey, false);
    self.highlighted = NO;
}
@end

@interface NFSViewController : UIViewController <UIDocumentPickerDelegate>
- (void)foreground;
- (void)background;
@end
@implementation NFSViewController
{
    MTKView* _metal;
    NFSGameInputView* _pointer;
    UIScrollView* _launcher;
    UIStackView* _stack;
    UIView* _controls;
    UILabel* _status;
    UILabel* _osd;
    UISwitch* _vibrationSwitch;
    UISwitch* _osdSwitch;
    UISwitch* _logSwitch;
    UISwitch* _tiltModeSwitch;
    NSMutableArray<NFSKeyButton*>* _keys;
    NFSSymbolButton* _backButton;
    NFSSymbolButton* _keyboardButton;
    NFSSymbolButton* _visibilityButton;
    NFSSymbolButton* _tiltButton;
    UIButton* _launchButton;
    UIButton* _importButton;
    CMMotionManager* _motion;
    CADisplayLink* _displayLink;
    BOOL _playing;
    BOOL _editing;
    BOOL _busy;
    BOOL _overlay;
    BOOL _driving;
    BOOL _takingText;
    BOOL _touchVisible;
    BOOL _tiltEnabled;
    BOOL _tiltSuspended;
    BOOL _applicationActive;
    BOOL _audioInterrupted;
    CFTimeInterval _audioRecoveryTime;
    NSInteger _tiltMode;
    CGFloat _keyboardInset;
    double _steering;
    BOOL _calibrated;
    UIInterfaceOrientation _motionOrientation;
    BOOL _padKeys[256];
    double _lastCPU;
    double _lastOSDTime;
    double _lastDataScanTime;
    NSString* _detectedGamePath;
    BOOL _gameReady;
    std::thread _worker;
    std::atomic<bool> _workerFinished;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    _workerFinished = true;
    _applicationActive = YES;
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.055 blue:0.09 alpha:1];
    _keys = [NSMutableArray array];
    _metal = [[MTKView alloc] initWithFrame:self.view.bounds];
    _metal.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_metal];
    nfsios::attachMetal((__bridge void*)_metal);
    _pointer = [[NFSGameInputView alloc] initWithFrame:self.view.bounds];
    _pointer.multipleTouchEnabled = YES;
    [self.view addSubview:_pointer];
    _controls = [[NFSControlSurface alloc] initWithFrame:self.view.bounds];
    _controls.autoresizingMask = _metal.autoresizingMask;
    _controls.hidden = YES;
    [self.view addSubview:_controls];
    NSArray* names = @[@"left", @"right", @"accelerate", @"brake", @"handbrake", @"pause", @"gear_up", @"gear_down", @"camera", @"horn", @"recover", @"look_behind", @"spike_strip", @"headlights"];
    NSArray* labels = @[@"左转", @"右转", @"油门", @"刹车", @"手刹", @"暂停", @"升挡", @"降挡", @"视角", @"喇叭", @"复位", @"后视", @"路障", @"车灯"];
    unsigned codes[] = {37, 39, 38, 40, 32, 27, 'A', 'Z', 'C', 'H', 'R', 'B', 'S', 'L'};
    for (unsigned index = 0; index < names.count; ++index)
    {
        NFSKeyButton* button = [[NFSKeyButton alloc] initWithFrame:CGRectZero];
        button.virtualKey = codes[index];
        button.tag = index;
        button.symbol = names[index];
        button.pulse = index == 5 || index == 6 || index == 7 || index == 8 || index == 10 || index == 12 || index == 13;
        button.accessibilityLabel = labels[index];
        [_controls addSubview:button];
        [_keys addObject:button];
        if (index == 5) [button addTarget:self action:@selector(suspendTilt) forControlEvents:UIControlEventTouchDown];
    }
    _backButton = [[NFSSymbolButton alloc] initWithFrame:CGRectZero];
    _backButton.symbol = @"back";
    _backButton.accessibilityLabel = @"返回";
    [_backButton addTarget:self action:@selector(gameBack) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_backButton];
    _backButton.hidden = YES;
    _keyboardButton = [[NFSSymbolButton alloc] initWithFrame:CGRectZero];
    _keyboardButton.symbol = @"keyboard";
    _keyboardButton.accessibilityLabel = @"输入";
    [_keyboardButton addTarget:self action:@selector(inputText) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_keyboardButton];
    _keyboardButton.hidden = YES;
    _visibilityButton = [[NFSSymbolButton alloc] initWithFrame:CGRectZero];
    _visibilityButton.symbol = @"visibility";
    _visibilityButton.accessibilityLabel = @"触控按键";
    [_visibilityButton addTarget:self action:@selector(toggleControls) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_visibilityButton];
    _visibilityButton.hidden = YES;
    _tiltButton = [[NFSSymbolButton alloc] initWithFrame:CGRectZero];
    _tiltButton.symbol = @"tilt";
    _tiltButton.accessibilityLabel = @"重力转向";
    [_tiltButton addTarget:self action:@selector(toggleTilt) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_tiltButton];
    _tiltButton.hidden = YES;
    _osd = [UILabel new];
    _osd.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    _osd.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    _osd.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
    _osd.numberOfLines = 3;
    [self.view addSubview:_osd];
    _launcher = [UIScrollView new];
    _launcher.backgroundColor = [UIColor colorWithRed:0.035 green:0.055 blue:0.09 alpha:0.97];
    [self.view addSubview:_launcher];
    _stack = [UIStackView new];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 10;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_launcher addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_launcher.contentLayoutGuide.topAnchor constant:20],
        [_stack.bottomAnchor constraintEqualToAnchor:_launcher.contentLayoutGuide.bottomAnchor constant:-24],
        [_stack.centerXAnchor constraintEqualToAnchor:_launcher.frameLayoutGuide.centerXAnchor],
        [_stack.widthAnchor constraintEqualToAnchor:_launcher.frameLayoutGuide.widthAnchor constant:-48]]];
    UILabel* title = [UILabel new];
    title.text = @"NFS3";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:30 weight:UIFontWeightHeavy];
    [_stack addArrangedSubview:title];
    _status = [UILabel new];
    _status.numberOfLines = 0;
    _status.textColor = [UIColor colorWithRed:0.5 green:0.8 blue:1 alpha:1];
    _status.font = [UIFont systemFontOfSize:14];
    [_stack addArrangedSubview:_status];
    _launchButton = actionButton(@"启动游戏", self, @selector(startGame));
    [_stack addArrangedSubview:_launchButton];
    _importButton = actionButton(@"导入游戏数据", self, @selector(importGame));
    [_stack addArrangedSubview:_importButton];
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    _tiltEnabled = [defaults boolForKey:@"tilt"];
    _tiltMode = [defaults integerForKey:@"tiltMode"] == 2 ? 2 : 1;
    _touchVisible = ![defaults objectForKey:@"touchVisible"] || [defaults boolForKey:@"touchVisible"];
    _tiltModeSwitch = [self addSwitch:NSLocalizedString(@"tilt.manual", nil) value:_tiltMode == 2];
    [_tiltModeSwitch removeTarget:self action:@selector(settingsChanged) forControlEvents:UIControlEventValueChanged];
    [_tiltModeSwitch addTarget:self action:@selector(tiltModeChanged) forControlEvents:UIControlEventValueChanged];
    _tiltModeSwitch.accessibilityHint = NSLocalizedString(@"tilt.manual.hint", nil);
    _vibrationSwitch = [self addSwitch:@"震动" value:![defaults objectForKey:@"vibration"] || [defaults boolForKey:@"vibration"]];
    _osdSwitch = [self addSwitch:@"显示 FPS / CPU / GPU / 内存" value:[defaults boolForKey:@"osd"]];
    _logSwitch = [self addSwitch:@"保存日志" value:[defaults boolForKey:@"logging"]];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--metal-diagnostic"]) _logSwitch.on = YES;
    [_stack addArrangedSubview:actionButton(@"编辑触控布局", self, @selector(editLayout))];
    UILabel* notice = [UILabel new];
    notice.text = @"将 FEDATA 和 GAMEDATA 放到「文件」App →「我的 iPhone / iPad」→ NFS3 → data，与 EXE、DLL、install.win 同级。日志保存在 log/log.log。";
    notice.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    notice.font = [UIFont systemFontOfSize:12];
    notice.numberOfLines = 0;
    [_stack addArrangedSubview:notice];
    _motion = [CMMotionManager new];
    _tiltButton.enabled = _motion.deviceMotionAvailable;
    _tiltButton.alpha = _tiltButton.enabled ? 1 : 0.35;
    _motion.deviceMotionUpdateInterval = 1.0 / 60;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self settingsChanged];
    [self refreshStatus];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(background) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(foreground) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardFrameChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    NSArray* arguments = NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--metal-diagnostic"])
        dispatch_async(dispatch_get_main_queue(), ^{ [self diagnostic]; });
    if ([arguments containsObject:@"--launch-game"])
        dispatch_async(dispatch_get_main_queue(), ^{ [self startGame]; });
    if ([arguments containsObject:@"--layout-preview"])
        dispatch_async(dispatch_get_main_queue(), ^{ [self editLayout]; });
    if ([arguments containsObject:@"--controls-preview"] || [arguments containsObject:@"--menu-preview"])
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL driving = [arguments containsObject:@"--controls-preview"];
            nfs3hp::Application game("nfs3.exe");
            nfsios::setRaceActive(driving);
            nfsios::updateGameState(&game);
            self->_playing = YES; self->_pointer.enabled = YES;
            self->_launcher.hidden = YES;
            self->_osdSwitch.on = ![arguments containsObject:@"--osd-off"];
            self->_osd.hidden = !self->_osdSwitch.on;
            if ([arguments containsObject:@"--tilt-preview"]) self->_tiltEnabled = YES;
            if ([arguments containsObject:@"--tilt-manual-preview"]) { self->_tiltEnabled = YES; self->_tiltMode = 2; }
            [self updateControlVisibility];
            [self.view setNeedsLayout];
        });
    if ([arguments containsObject:@"--keyboard-preview"])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            self->_playing = YES; self->_pointer.enabled = YES;
            self->_launcher.hidden = YES;
            [self inputText];
        });
    if ([arguments containsObject:@"--exit-diagnostic"])
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_playing = YES; self->_launcher.hidden = YES;
            self->_workerFinished = false;
            self->_worker = std::thread([self] {
                nfsios::gameInputDiagnostic();
                self->_workerFinished = true;
            });
        });
}
- (UISwitch*)addSwitch:(NSString*)title value:(BOOL)value
{
    UILabel* label = [UILabel new];
    label.text = title;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14];
    UISwitch* toggle = [UISwitch new];
    toggle.on = value;
    [toggle addTarget:self action:@selector(settingsChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    [_stack addArrangedSubview:row];
    return toggle;
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if (@available(iOS 26.0, *))
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) return UIInterfaceOrientationMaskAll;
    return UIInterfaceOrientationMaskLandscape;
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _launcher.frame = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGRect picture = self.view.bounds;
    picture.size.height = MAX(1, picture.size.height - _keyboardInset);
    _metal.frame = picture;
    _pointer.frame = picture;
    _backButton.frame = CGRectMake(safe.origin.x + 12, safe.origin.y + (_osd.hidden ? 8 : 64), 44, 40);
    _keyboardButton.frame = CGRectMake(CGRectGetMaxX(safe) - 220, safe.origin.y + 8, 44, 40);
    _visibilityButton.frame = CGRectMake(CGRectGetMaxX(safe) - 108, safe.origin.y + 8, 44, 40);
    _tiltButton.frame = CGRectMake(CGRectGetMaxX(safe) - 164, safe.origin.y + 8, 44, 40);
    if (!_editing) [self arrangeControls];
    if (_playing)
    {
        [NSUserDefaults.standardUserDefaults setDouble:safe.size.width forKey:@"touchReferenceWidth"];
        [NSUserDefaults.standardUserDefaults setDouble:safe.size.height forKey:@"touchReferenceHeight"];
    }
    [self arrangeOSD];
}
- (void)arrangeOSD
{
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat width = MIN(205, MAX(1, safe.size.width - 16));
    CGFloat height = 45;
    _osd.frame = CGRectMake(safe.origin.x + 8, safe.origin.y + 8, width, height);
}
- (void)arrangeControls
{
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    NSArray<NSValue*>* frames = NFSDefaultControlFrames(safe, 1 / UIScreen.mainScreen.scale, _osdSwitch.on ? 56 : 0);
    NSDictionary* layout = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"symbolLayout"];
    CGFloat scale = NFSControlLayoutScale(safe.size, _osdSwitch.on ? 56 : 0);
    for (unsigned index = 0; index < _keys.count; ++index)
    {
        _keys[index].frame = NFSResolveControlFrame(frames[index].CGRectValue, safe, scale, layout[_keys[index].symbol]);
    }
}
- (void)settingsChanged
{
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:_vibrationSwitch.on forKey:@"vibration"];
    NFSSetHapticsEnabled(_vibrationSwitch.on);
    [defaults setBool:_osdSwitch.on forKey:@"osd"];
    [defaults setBool:_logSwitch.on forKey:@"logging"];
    _osd.hidden = !_osdSwitch.on || !_playing;
    [self.view setNeedsLayout];
    [self arrangeControls]; [self arrangeOSD];
    [NSFileManager.defaultManager createDirectoryAtPath:logPath() withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* path = _logSwitch.on ? [logPath() stringByAppendingPathComponent:@"log.log"] : @"/dev/null";
    freopen(path.fileSystemRepresentation, "a", stderr);
    setvbuf(stderr, nullptr, _IOLBF, 0);
    win32::platform::log("NFS3_BUILD: %s (%s)", [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String], [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String]);
}
- (void)refreshStatus
{
    _detectedGamePath = gamePath();
    NSError* failure = nil;
    BOOL prepared = prepareGameDirectory(_detectedGamePath, &failure);
    _gameReady = directoryContainsGame(_detectedGamePath);
    _status.text = failure ? failure.localizedDescription : (_gameReady ? @"游戏数据已就绪。" : @"请放入 FEDATA 和 GAMEDATA。EXE、DLL 和 INSTALL.WIN 已内置。");
    _launchButton.enabled = _gameReady && prepared && !_busy;
}
- (void)importGame
{
    if (_busy || _playing) return;
    UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)picker didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
{
    (void)picker;
    if (!urls.count) return;
    NSURL* selected = urls.firstObject;
    _busy = YES;
    _launchButton.enabled = NO;
    _importButton.enabled = NO;
    _status.text = @"正在复制并检查游戏目录…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [selected startAccessingSecurityScopedResource];
        __block NSError* failure = nil;
        NSFileCoordinator* coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:selected options:NSFileCoordinatorReadingWithoutChanges error:&failure byAccessor:^(NSURL* source) {
            NSString* stage = [documentsPath() stringByAppendingPathComponent:[@"Import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            NSFileManager* manager = NSFileManager.defaultManager;
            NSString* root = source.path;
            if (!directoryContainsGame(root))
            {
                for (NSString* child in [manager contentsOfDirectoryAtPath:root error:nil])
                {
                    NSString* candidate = [root stringByAppendingPathComponent:child];
                    if (directoryContainsGame(candidate)) { root = candidate; break; }
                }
            }
            if (!directoryContainsGame(root))
            {
                failure = [NSError errorWithDomain:@"NFSImport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"选择的目录缺少 FEDATA 或 GAMEDATA。请选择包含这两个文件夹的目录。"}];
                return;
            }
            NSDirectoryEnumerator* enumeration = [manager enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey] options:0 errorHandler:^BOOL(NSURL*, NSError* error) { failure = error; return NO; }];
            for (NSURL* item in enumeration)
            {
                NSNumber* link = nil;
                if (![item getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:&failure] || link.boolValue)
                {
                    if (!failure) failure = [NSError errorWithDomain:@"NFSImport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"游戏目录不能包含符号链接。"}];
                    return;
                }
            }
            if (failure) return;
            NSString* resolvedRoot = [NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path;
            if ([resolvedRoot isEqualToString:[[NSURL fileURLWithPath:dataPath()] URLByResolvingSymlinksInPath].path])
            {
                prepareGameDirectory(dataPath(), &failure);
                return;
            }
            if (![manager createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:&failure]) return;
            for (NSString* name in @[@"fedata", @"gamedata", @"nfs3.exe", @"eacsnd.dll", @"softtria.dll", @"voodoo2a.dll", @"install.win"])
            {
                NSString* original = caseMatchedPath(root, name);
                if ([manager fileExistsAtPath:original] && ![manager copyItemAtPath:original toPath:[stage stringByAppendingPathComponent:original.lastPathComponent] error:&failure]) break;
            }
            if (failure || !prepareGameDirectory(stage, &failure)) { [manager removeItemAtPath:stage error:nil]; return; }
            NSString* destination = dataPath();
            NSString* backup = [documentsPath() stringByAppendingPathComponent:@"data.backup"];
            BOOL hadGame = [manager fileExistsAtPath:destination];
            if ([manager fileExistsAtPath:backup])
            {
                failure = [NSError errorWithDomain:@"NFSImport" code:3 userInfo:@{NSLocalizedDescriptionKey:@"发现上次导入备份 data.backup，请先在文件 App 中保留或移走备份。"}];
            }
            else if (hadGame) [manager moveItemAtPath:destination toPath:backup error:&failure];
            if (!failure)
            {
                if ([manager moveItemAtPath:stage toPath:destination error:&failure])
                    [NSUserDefaults.standardUserDefaults setObject:@"data" forKey:@"gameFolder"];
                else if (hadGame) [manager moveItemAtPath:backup toPath:destination error:nil];
            }
            [manager removeItemAtPath:stage error:nil];
        }];
        if (scoped) [selected stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            self->_importButton.enabled = YES;
            [self refreshStatus];
            if (failure) self->_status.text = failure.localizedDescription;
        });
    });
}
- (void)startGame
{
    if (_busy || _playing) return;
    [self refreshStatus];
    if (!_launchButton.enabled) return;
    if (_worker.joinable()) _worker.join();
    _playing = YES;
    memset(_padKeys, 0, sizeof(_padKeys));
    nfsios::releaseInput();
    _driving = NO; _takingText = NO;
    _overlay = NO;
    _launcher.hidden = YES;
    _controls.hidden = YES;
    _backButton.hidden = NO;
    _keyboardButton.hidden = NO;
    _osd.hidden = !_osdSwitch.on;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    _calibrated = NO;
    _tiltSuspended = NO;
    _lastOSDTime = 0; _lastCPU = 0;
    std::string path(gamePath().fileSystemRepresentation);
    NSString* relativeRoot = [gamePath() substringFromIndex:documentsPath().length];
    NSString* profileKey = [@"touchProfileV2:" stringByAppendingString:relativeRoot];
    nfsios::DrivingMode mode = [self drivingMode];
    BOOL initializeControls = ![NSUserDefaults.standardUserDefaults objectForKey:profileKey] || ![NSFileManager.defaultManager fileExistsAtPath:caseMatchedPath(gamePath(), @"fedata/config/config.dat")];
    _pointer.enabled = YES;
    [self updateControlVisibility];
    [self.view setNeedsLayout];
    _workerFinished = false;
    _worker = std::thread([self, path, initializeControls, mode, profileKey] {
        @autoreleasepool {
            nfsios::runGame(path.c_str(), initializeControls, mode);
            if (nfsios::controlsInitialized()) [NSUserDefaults.standardUserDefaults setObject:@"configured" forKey:profileKey];
        }
        self->_workerFinished = true;
    });
}
- (void)gameBack
{
    if (!_playing) return;
    NFSTouchFeedback();
    if (_pointer.isFirstResponder) { [_pointer resignFirstResponder]; return; }
    [self suspendTilt];
    nfsios::key(27, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ nfsios::key(27, false); });
}
- (void)inputText
{
    if (!_playing) return;
    NFSTouchFeedback();
    if (_pointer.isFirstResponder) [_pointer resignFirstResponder];
    else [_pointer becomeFirstResponder];
}
- (void)releaseTouchControls
{
    for (NFSKeyButton* button in _keys) [button cancelPress];
}
- (void)updateControlVisibility
{
    BOOL driving = nfsios::inRace();
    _controls.hidden = !_playing || !driving || !_touchVisible;
    _backButton.hidden = !_playing || (driving && _touchVisible);
    _keyboardButton.hidden = !_playing;
    _visibilityButton.hidden = !_playing;
    _tiltButton.hidden = !_playing;
    _visibilityButton.active = _touchVisible;
    _visibilityButton.accessibilityValue = _touchVisible ? @"显示" : @"隐藏";
    _tiltButton.active = _tiltEnabled;
    _tiltButton.accessibilityValue = _tiltEnabled ? @"开启" : @"关闭";
    for (NFSKeyButton* button in _keys)
    {
        BOOL hidden = (_tiltEnabled && (button.tag < 2 || (button.tag < 4 && _tiltMode == 1)))
            || ((button.tag == 6 || button.tag == 7) && !nfsios::manualGears())
            || (button.tag == 12 && !nfsios::policeCar());
        if (hidden && !button.hidden) [button cancelPress];
        button.hidden = hidden;
    }
}
- (void)suspendTilt
{
    _tiltSuspended = YES;
    _pointer.brakeEnabled = NO;
    [self updateTiltPedals:NO];
    win32::GamepadState state{};
    nfsios::setController(0, state);
}
- (nfsios::DrivingMode)drivingMode
{
    return GCController.controllers.count > 0 ? nfsios::DrivingMode::Controller
        : _tiltEnabled ? nfsios::DrivingMode::Tilt : nfsios::DrivingMode::Keyboard;
}
- (void)updateTiltPedals:(BOOL)automatic
{
    nfsios::key(38, automatic && !_pointer.braking, 2);
    nfsios::key(40, automatic && _pointer.braking, 2);
}
- (void)tiltModeChanged
{
    _tiltMode = _tiltModeSwitch.on ? 2 : 1;
    [NSUserDefaults.standardUserDefaults setInteger:_tiltMode forKey:@"tiltMode"];
    [self releaseTouchControls];
    _pointer.brakeEnabled = NO;
    [self updateTiltPedals:NO];
    [self updateControlVisibility];
}
- (void)toggleControls
{
    if (!_playing) return;
    NFSTouchFeedback();
    [self releaseTouchControls];
    [_pointer cancelPointer];
    _touchVisible = !_touchVisible;
    [NSUserDefaults.standardUserDefaults setBool:_touchVisible forKey:@"touchVisible"];
    [self updateControlVisibility];
}
- (void)toggleTilt
{
    if (!_playing) return;
    NFSTouchFeedback();
    [self releaseTouchControls];
    _tiltEnabled = !_tiltEnabled;
    _tiltSuspended = NO;
    _pointer.brakeEnabled = NO;
    [self updateTiltPedals:NO];
    _calibrated = NO;
    _steering = 0;
    if (_tiltEnabled)
    {
        _touchVisible = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"touchVisible"];
    }
    win32::GamepadState state{};
    nfsios::setController(0, state);
    [NSUserDefaults.standardUserDefaults setBool:_tiltEnabled forKey:@"tilt"];
    nfsios::requestDrivingMode([self drivingMode]);
    [self updateControlVisibility];
}
- (void)updateKeyboardFromGame
{
    BOOL takingText = nfsios::takingText();
    if (_takingText == takingText) return;
    _takingText = takingText;
    if (takingText) [_pointer becomeFirstResponder];
    else [_pointer resignFirstResponder];
}
- (void)keyboardFrameChanged:(NSNotification*)notification
{
    CGRect keyboard = [self.view convertRect:[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromCoordinateSpace:self.view.window.screen.coordinateSpace];
    CGRect overlap = CGRectIntersection(self.view.bounds, keyboard);
    BOOL docked = !CGRectIsNull(overlap) && CGRectGetMaxY(keyboard) >= CGRectGetMaxY(self.view.bounds) - 1 && overlap.size.width >= self.view.bounds.size.width * 0.8;
    _keyboardInset = docked ? overlap.size.height : 0;
    [_pointer cancelPointer];
    [self.view setNeedsLayout];
}
- (void)resumeGame
{
    _overlay = NO;
    memset(_padKeys, 0, sizeof(_padKeys));
    _tiltSuspended = NO;
    _calibrated = NO;
    nfsios::setActive(true);
    _audioRecoveryTime = 0;
    [self recoverAudio];
    [_metal setNeedsDisplay];
}
- (void)background
{
    if (!_applicationActive) return;
    _applicationActive = NO;
    nfsios::stopHaptics();
    win32::platform::log("NFS3_LIFECYCLE: background playing=%d", _playing);
    [self releaseTouchControls];
    [self suspendTilt];
    [_motion stopDeviceMotionUpdates];
    [_pointer cancelPointer];
    [_pointer resignFirstResponder];
    _takingText = NO;
    nfsios::setActive(false);
    nfsios::audioActive(false);
    memset(_padKeys, 0, sizeof(_padKeys));
    _calibrated = NO;
}
- (void)foreground
{
    BOOL wasActive = _applicationActive;
    _applicationActive = YES;
    if (!wasActive) _audioInterrupted = NO;
    win32::platform::log("NFS3_LIFECYCLE: foreground playing=%d interrupted=%d", _playing, _audioInterrupted);
    nfsios::setActive(true);
    if (!_busy && !_playing && !_editing) [self refreshStatus];
    if (!wasActive && !_overlay && _playing) [self resumeGame];
}
- (void)audioInterrupted:(NSNotification*)notification
{
    if (!NSThread.isMainThread)
    {
        dispatch_async(dispatch_get_main_queue(), ^{ [self audioInterrupted:notification]; });
        return;
    }
    _audioInterrupted = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
    win32::platform::log("NFS3_LIFECYCLE: audio interrupted=%d foreground=%d", _audioInterrupted, _applicationActive);
    nfsios::audioActive(!_audioInterrupted && _applicationActive && !_overlay);
    _audioRecoveryTime = CACurrentMediaTime() + (_audioInterrupted ? 0.25 : 0);
}
- (void)recoverAudio
{
    if (!_applicationActive || !_playing || _overlay || CACurrentMediaTime() < _audioRecoveryTime) return;
    if (!_audioInterrupted && nfsios::audioRunning()) return;
    _audioRecoveryTime = CACurrentMediaTime() + 1;
    _audioInterrupted = !nfsios::audioActive(true);
}
- (void)tick:(CADisplayLink*)link
{
    nfsios::updateHaptics(_playing && !_overlay);
    if (!_playing && !_editing && !_busy && link.timestamp - _lastDataScanTime > 1)
    {
        NSString* path = gamePath();
        if (!_gameReady || ![_detectedGamePath isEqualToString:path] || _gameReady != directoryContainsGame(path)) [self refreshStatus];
        _lastDataScanTime = link.timestamp;
    }
    if (_playing && !_overlay && UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
    {
        [self recoverAudio];
        BOOL driving = nfsios::inRace();
        if (_driving != driving)
        {
            _driving = driving;
            _tiltSuspended = NO;
            _calibrated = NO;
            _steering = 0;
            [_pointer cancelPointer];
            if (driving) [_pointer resignFirstResponder];
            [self releaseTouchControls];
        }
        [self updateControlVisibility];
        [self arrangeOSD];
        [self updateKeyboardFromGame];
        BOOL current[256]{};
        NSArray<GCController*>* pads = GCController.controllers;
        nfsios::requestDrivingMode([self drivingMode]);
        BOOL motionAllowed = _tiltEnabled && driving && !_tiltSuspended && !pads.count && _motion.deviceMotionAvailable;
        if (motionAllowed && !_motion.deviceMotionActive) [_motion startDeviceMotionUpdates];
        if (!motionAllowed && _motion.deviceMotionActive) [_motion stopDeviceMotionUpdates];
        _pointer.brakeEnabled = motionAllowed && _tiltMode == 1;
        [self updateTiltPedals:motionAllowed && _motion.deviceMotion != nil && _tiltMode == 1];
        for (unsigned index = 0; index < 2; ++index)
        {
            win32::GamepadState state{};
            if (index < pads.count && pads[index].extendedGamepad)
            {
                GCExtendedGamepad* pad = pads[index].extendedGamepad;
                float horizontal = fabs(pad.leftThumbstick.xAxis.value) > fabs(pad.dpad.xAxis.value) ? pad.leftThumbstick.xAxis.value : pad.dpad.xAxis.value;
                float vertical = fabs(pad.leftThumbstick.yAxis.value) > fabs(pad.dpad.yAxis.value) ? pad.leftThumbstick.yAxis.value : pad.dpad.yAxis.value;
                state.axes[0] = horizontal * 32767;
                state.axes[1] = -vertical * 32767;
                if (nfsios::inRace())
                    state.axes[1] = (MAX(pad.leftTrigger.value, pad.buttonB.value) - MAX(pad.rightTrigger.value, pad.buttonA.value)) * 32767;
                state.axes[4] = pad.rightTrigger.value * 65534 - 32767;
                state.axes[5] = pad.leftTrigger.value * 65534 - 32767;
                GCControllerButtonInput* buttons[] = {pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.leftShoulder, pad.rightShoulder, pad.buttonOptions, pad.buttonMenu};
                for (unsigned button = 0; button < 8; ++button) if (buttons[button].pressed) state.buttons |= uint64_t(1) << button;
                if (index == 0)
                {
                    current[37] = horizontal < -0.3;
                    current[39] = horizontal > 0.3;
                    if (nfsios::inRace())
                    {
                        current[38] = pad.rightTrigger.pressed || pad.buttonA.pressed;
                        current[40] = pad.leftTrigger.pressed || pad.buttonB.pressed;
                    }
                    else
                    {
                        current[38] = vertical > 0.3;
                        current[40] = vertical < -0.3;
                        current[13] = pad.buttonA.pressed;
                        current[27] = pad.buttonB.pressed;
                    }
                    current[32] = pad.buttonX.pressed;
                    current['C'] = pad.buttonY.pressed;
                    current['Z'] = pad.leftShoulder.pressed;
                    current['A'] = pad.rightShoulder.pressed;
                    current[27] |= pad.buttonMenu.pressed;
                }
                else if (nfsios::inRace())
                {
                    current['D'] = pad.buttonX.pressed;
                    current['Q'] = pad.buttonY.pressed;
                    current['G'] = pad.leftShoulder.pressed;
                    current['F'] = pad.rightShoulder.pressed;
                    current[27] |= pad.buttonMenu.pressed;
                }
            }
            if (index == 0 && motionAllowed && _motion.deviceMotion)
            {
                CMAcceleration gravity = _motion.deviceMotion.gravity;
                UIInterfaceOrientation orientation = self.view.window.windowScene.interfaceOrientation;
                if (!_calibrated || _motionOrientation != orientation)
                {
                    _steering = 0; _calibrated = YES; _motionOrientation = orientation;
                }
                double normalized = (orientation == UIInterfaceOrientationLandscapeRight ? -gravity.y : gravity.y) / 0.35;
                double magnitude = std::clamp((fabs(normalized) - 0.05) / 0.95, 0.0, 1.0);
                double target = std::copysign(magnitude, normalized);
                _steering = _steering * 0.28 + target * 0.72;
                state.axes[0] = _steering * 32767;
            }
            else if (index == 0)
            {
                if (!nfsios::inRace()) _calibrated = NO;
            }
            nfsios::setController(index, state);
        }
        for (unsigned key = 0; key < 256; ++key)
        {
            if (current[key] != _padKeys[key])
            {
                nfsios::key(key, current[key], 1);
                _padKeys[key] = current[key];
            }
        }
    }
    if (_playing && _worker.joinable() && _workerFinished)
    {
        _worker.join();
        _playing = NO; _overlay = NO; _takingText = NO;
        [_pointer cancelPointer]; [_pointer resignFirstResponder]; _pointer.enabled = NO;
        nfsios::releaseInput();
        _launcher.hidden = NO; _osd.hidden = YES;
        _pointer.brakeEnabled = NO;
        [_motion stopDeviceMotionUpdates];
        [self releaseTouchControls];
        [self updateControlVisibility];
        UIApplication.sharedApplication.idleTimerDisabled = NO;
        [self refreshStatus];
    }
    if (_playing && !_osd.hidden && link.timestamp - _lastOSDTime > 0.5)
    {
        task_basic_info_data_t basic{};
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        task_info(mach_task_self(), TASK_BASIC_INFO, reinterpret_cast<task_info_t>(&basic), &count);
        task_thread_times_info_data_t times{};
        count = TASK_THREAD_TIMES_INFO_COUNT;
        task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, reinterpret_cast<task_info_t>(&times), &count);
        double cpu = times.user_time.seconds + times.system_time.seconds + basic.user_time.seconds + basic.system_time.seconds
            + (times.user_time.microseconds + times.system_time.microseconds + basic.user_time.microseconds + basic.system_time.microseconds) / 1e6;
        double load = _lastOSDTime ? std::max(0.0, (cpu - _lastCPU) / (link.timestamp - _lastOSDTime) * 100) : 0;
        task_vm_info_data_t memory{};
        count = TASK_VM_INFO_COUNT;
        task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&memory), &count);
        _osd.text = [NSString stringWithFormat:@"FPS %.1f   CPU %.0f%%\nGPU %.2f ms   RAM %.0f MB", nfsios::framesPerSecond(), load, nfsios::gpuMilliseconds(), memory.phys_footprint / 1048576.0];
        _lastCPU = cpu; _lastOSDTime = link.timestamp;
    }
}
- (void)editLayout
{
    if (_busy || _playing) return;
    _editing = YES;
    nfsios::releaseInput();
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    CGSize reference = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets).size;
    double width = [defaults doubleForKey:@"touchReferenceWidth"], height = [defaults doubleForKey:@"touchReferenceHeight"];
    if (width > 0 && height > 0 && std::abs(width / height - reference.width / reference.height) < 0.2 * reference.width / reference.height)
        reference = CGSizeMake(width, height);
    if (reference.height > reference.width) reference = CGSizeMake(reference.height, reference.width);
    NFSLayoutEditorController* editor = [[NFSLayoutEditorController alloc] initWithReferenceSize:reference pixel:1 / UIScreen.mainScreen.scale header:_osdSwitch.on ? 56 : 0 completion:^{
        self->_editing = NO;
        [self arrangeControls];
    }];
    [self presentViewController:editor animated:YES completion:nil];
}
- (void)automaticKeyboardDiagnostic
{
    nfs3hp::Application game("nfs3.exe");
    BOOL previousEnabled = _pointer.enabled;
    _playing = YES; _pointer.enabled = YES; _takingText = NO;
    nfsios::setRaceActive(false);
    auto update = [&] { nfsios::updateGameState(&game); [self updateKeyboardFromGame]; };
    game.getMemory<uint8_t>(0x558b10) = 1;
    game.getMemory<uint32_t>(0x558b14) = 1;
    update(); NFS2_ASSERT(!_pointer.isFirstResponder);
    game.getMemory<uint32_t>(0x558b14) = 3;
    game.getMemory<uint32_t>(0x558b18) = 0x45cdd0;
    update(); NFS2_ASSERT(_pointer.isFirstResponder);
    UITextField* field = (UITextField*)_pointer.subviews.firstObject;
    NFS2_ASSERT(![_pointer textFieldShouldReturn:field] && _pointer.isFirstResponder);
    x86::CPU cpu{};
    win32::MSG message{};
    for (unsigned expected : {0x100u, 0x102u, 0x101u})
        NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == expected && message.wParam == 13);
    update(); NFS2_ASSERT(_pointer.isFirstResponder);
    [self inputText]; update(); NFS2_ASSERT(!_pointer.isFirstResponder);
    [self inputText]; NFS2_ASSERT(_pointer.isFirstResponder);
    [self gameBack]; update(); NFS2_ASSERT(!_pointer.isFirstResponder);
    game.getMemory<uint8_t>(0x558b10) = 0;
    update(); NFS2_ASSERT(!_pointer.isFirstResponder);
    game.getMemory<uint8_t>(0x558b10) = 1;
    update(); NFS2_ASSERT(_pointer.isFirstResponder);
    game.getMemory<uint32_t>(0x558b14) = 2;
    update(); NFS2_ASSERT(!_pointer.isFirstResponder);
    game.getMemory<uint32_t>(0x558b14) = 3;
    nfsios::setRaceActive(true);
    game.getMemory<uint32_t>(0x7a3d10) = 1;
    update(); NFS2_ASSERT(_pointer.isFirstResponder);
    game.getMemory<uint32_t>(0x7a3d10) = 0;
    update(); NFS2_ASSERT(!_pointer.isFirstResponder);
    game.getMemory<uint32_t>(0x7a3d10) = 1;
    update(); NFS2_ASSERT(_pointer.isFirstResponder);
    [self background]; NFS2_ASSERT(!_pointer.isFirstResponder);
    [self foreground]; update(); NFS2_ASSERT(_pointer.isFirstResponder);
    game.getMemory<uint8_t>(0x558b10) = 0;
    nfsios::setRaceActive(false);
    update(); NFS2_ASSERT(!_pointer.isFirstResponder);
    _playing = NO; _pointer.enabled = previousEnabled;
    win32::platform::log("NFS3_AUTO_KEYBOARD_DIAGNOSTIC: PASS actual UIKit first responder follows guest text-mode entry/exit, Return stays open until guest closes, manual toggle/Back are respected, next prompt and paused text reopen, driving suppresses text and foreground restores active prompt");
}
- (void)lifecycleDiagnostic
{
    BOOL previousPlaying = _playing, previousEnabled = _pointer.enabled;
    BOOL previousActive = _applicationActive, previousInterruption = _audioInterrupted;
    CFTimeInterval previousRecoveryTime = _audioRecoveryTime;
    _playing = YES; _pointer.enabled = YES; _applicationActive = YES;
    auto interruption = [&](NSUInteger type) {
        [self audioInterrupted:[NSNotification notificationWithName:AVAudioSessionInterruptionNotification object:AVAudioSession.sharedInstance userInfo:@{AVAudioSessionInterruptionTypeKey:@(type)}]];
    };
    for (unsigned cycle = 0; cycle < 6; ++cycle)
    {
        [self background]; [self background];
        interruption(AVAudioSessionInterruptionTypeEnded);
        [self recoverAudio];
        NFS2_ASSERT(!nfsios::isActive() && !nfsios::audioRunning());
        std::mutex mutex;
        std::condition_variable condition;
        bool entered = false, completed = false;
        std::thread frame([&] {
            { std::lock_guard<std::mutex> guard(mutex); entered = true; }
            condition.notify_all();
            nfsios::presentTexture(nullptr);
            { std::lock_guard<std::mutex> guard(mutex); completed = true; }
            condition.notify_all();
        });
        {
            std::unique_lock<std::mutex> guard(mutex);
            NFS2_ASSERT(condition.wait_for(guard, std::chrono::seconds(2), [&] { return entered; }));
            NFS2_ASSERT(!condition.wait_for(guard, std::chrono::milliseconds(20), [&] { return completed; }));
        }
        interruption(AVAudioSessionInterruptionTypeBegan);
        [self foreground]; [self foreground];
        interruption(AVAudioSessionInterruptionTypeBegan);
        NFS2_ASSERT(nfsios::isActive());
        NFS2_ASSERT(_audioInterrupted && !nfsios::audioRunning());
        _audioRecoveryTime = 0;
        [self recoverAudio];
        NFS2_ASSERT(!_audioInterrupted && nfsios::audioRunning());
        {
            std::unique_lock<std::mutex> guard(mutex);
            NFS2_ASSERT(condition.wait_for(guard, std::chrono::seconds(2), [&] { return completed; }));
        }
        frame.join();
        interruption(AVAudioSessionInterruptionTypeEnded);
        NFS2_ASSERT(nfsios::isActive());
    }
    _playing = previousPlaying; _pointer.enabled = previousEnabled;
    _applicationActive = previousActive; _audioInterrupted = previousInterruption;
    _audioRecoveryTime = previousRecoveryTime;
    nfsios::setActive(previousActive);
    nfsios::audioActive(previousActive && !previousInterruption);
    win32::platform::log("NFS3_LIFECYCLE_DIAGNOSTIC: PASS six controller background/foreground cycles, presentation blocks/resumes, late audio-began recovers without an ended event, duplicate notifications are idempotent and background never resumes audio/gameplay");
}
- (void)controlVisibilityDiagnostic
{
    BOOL previousPlaying = _playing, previousVisible = _touchVisible, previousTilt = _tiltEnabled;
    BOOL previousOSD = _osdSwitch.on, previousEnabled = _pointer.enabled;
    BOOL previousTiltButtonEnabled = _tiltButton.enabled;
    NSInteger previousMode = _tiltMode;
    BOOL previousModeSwitch = _tiltModeSwitch.on;
    _tiltButton.enabled = YES;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    id savedTilt = [defaults objectForKey:@"tilt"], savedVisible = [defaults objectForKey:@"touchVisible"];
    id savedMode = [defaults objectForKey:@"tiltMode"];
    nfs3hp::Application game("nfs3.exe");
    _playing = YES; _pointer.enabled = YES; _touchVisible = YES; _tiltEnabled = NO;
    _tiltMode = 1; _tiltModeSwitch.on = NO;
    nfsios::setRaceActive(false);
    nfsios::updateGameState(&game);
    [self updateControlVisibility];
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    for (BOOL showing : {NO, YES})
    {
        _osdSwitch.on = showing; _osd.hidden = !showing;
        [self viewDidLayoutSubviews];
        NFS2_ASSERT(fabs(CGRectGetMinY(_backButton.frame) - safe.origin.y - (showing ? 64 : 8)) < 0.1);
        if (showing) NFS2_ASSERT(!CGRectIntersectsRect(_osd.frame, _backButton.frame));
        NFS2_ASSERT(!_backButton.hidden && !_visibilityButton.hidden && !_tiltButton.hidden);
    }
    nfsios::setRaceActive(true);
    game.getMemory<uint32_t>(0x7a3d10) = 0;
    game.getMemory<uint32_t>(0x6fd3a0) = 0;
    game.getMemory<uint32_t>(0x5e10b0) = 0x6fe000;
    game.getMemory<uint32_t>(0x6fe008) = 0x6fe100;
    game.getMemory<uint32_t>(0x6fe320) = 0x6fd52c;
    game.getMemory<uint32_t>(0x6fd548) = 1;
    game.getMemory<uint8_t>(0x6fe300) = 0;
    nfsios::updateGameState(&game);
    [self updateControlVisibility];
    NFS2_ASSERT(!_controls.hidden && _backButton.hidden);
    NFS2_ASSERT(_keys[6].hidden && _keys[7].hidden && _keys[12].hidden);
    NFS2_ASSERT([self.view hitTest:_keyboardButton.center withEvent:nil] == _keyboardButton);
    NFS2_ASSERT([self.view hitTest:_visibilityButton.center withEvent:nil] == _visibilityButton);
    NFS2_ASSERT([self.view hitTest:_tiltButton.center withEvent:nil] == _tiltButton);
    [_keys[2] press];
    [_keys[8] press];
    uint8_t state[256]{};
    nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] != 0 && state[0x2e] != 0);
    [self toggleControls];
    memset(state, 0, sizeof(state));
    nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0 && state[0x2e] == 0);
    NFS2_ASSERT(_controls.hidden && !_backButton.hidden && !_visibilityButton.hidden);
    NFS2_ASSERT([self.view hitTest:_keys[2].center withEvent:nil] == _pointer);
    [self toggleTilt];
    NFS2_ASSERT(_touchVisible && !_controls.hidden && _tiltButton.active);
    for (unsigned index = 0; index < 4; ++index) NFS2_ASSERT(_keys[index].hidden);
    NFS2_ASSERT(!_keys[4].hidden && !_keys[8].hidden);
    game.getMemory<uint32_t>(0x6fd548) = 0;
    game.getMemory<uint8_t>(0x6fe300) = 0x20;
    nfsios::updateGameState(&game);
    [self updateControlVisibility];
    NFS2_ASSERT(!_keys[6].hidden && !_keys[7].hidden && !_keys[12].hidden);
    NFSBrakeDiagnostic();
    _pointer.brakeEnabled = YES;
    [self updateTiltPedals:YES];
    memset(state, 0, sizeof(state)); nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0x80 && state[0x50] == 0);
    UITouch* brakeFinger = [UITouch new];
    NSSet* brakeTouches = [NSSet setWithObject:brakeFinger];
    [_pointer touchesBegan:brakeTouches withEvent:nil];
    [self updateTiltPedals:YES];
    memset(state, 0, sizeof(state)); nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0 && state[0x50] == 0x80);
    [_pointer touchesEnded:brakeTouches withEvent:nil];
    [self updateTiltPedals:YES];
    memset(state, 0, sizeof(state)); nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0x80 && state[0x50] == 0);
    _tiltModeSwitch.on = YES;
    [self tiltModeChanged];
    NFS2_ASSERT(_tiltMode == 2 && [defaults integerForKey:@"tiltMode"] == 2);
    NFS2_ASSERT(_keys[0].hidden && _keys[1].hidden && !_keys[2].hidden && !_keys[3].hidden && !_pointer.brakeEnabled);
    memset(state, 0, sizeof(state)); nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0 && state[0x50] == 0);
    [_keys[2] press]; [self updateTiltPedals:NO];
    memset(state, 0, sizeof(state)); nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0x80 && state[0x50] == 0);
    [_keys[2] releaseKey]; [_keys[3] press];
    memset(state, 0, sizeof(state)); nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0 && state[0x50] == 0x80);
    [_keys[3] releaseKey];
    _tiltModeSwitch.on = NO;
    [self tiltModeChanged];
    for (unsigned index = 0; index < 4; ++index) NFS2_ASSERT(_keys[index].hidden);
    _pointer.brakeEnabled = YES; [self updateTiltPedals:YES];
    win32::GamepadState axes{}; axes.axes[0] = 12000; axes.axes[1] = -32767;
    nfsios::setController(0, axes);
    [self suspendTilt];
    NFS2_ASSERT(nfsios::controller(0).axes[0] == 0 && nfsios::controller(0).axes[1] == 0);
    memset(state, 0, sizeof(state)); nfsios::keyboardState(state, sizeof(state));
    NFS2_ASSERT(state[0x48] == 0 && state[0x50] == 0);
    [self toggleTilt];
    for (unsigned index = 0; index < 4; ++index) NFS2_ASSERT(!_keys[index].hidden);
    game.getMemory<uint32_t>(0x7a3d10) = 1;
    nfsios::updateGameState(&game);
    [self updateControlVisibility];
    NFS2_ASSERT(_controls.hidden && !_backButton.hidden);
    nfsios::setRaceActive(false); nfsios::updateGameState(&game); nfsios::releaseInput();
    _playing = previousPlaying; _touchVisible = previousVisible; _tiltEnabled = previousTilt;
    _tiltSuspended = NO; _pointer.enabled = previousEnabled;
    _tiltButton.enabled = previousTiltButtonEnabled;
    _tiltMode = previousMode; _tiltModeSwitch.on = previousModeSwitch;
    _osdSwitch.on = previousOSD; _osd.hidden = !previousPlaying || !previousOSD;
    if (savedTilt) [defaults setObject:savedTilt forKey:@"tilt"]; else [defaults removeObjectForKey:@"tilt"];
    if (savedVisible) [defaults setObject:savedVisible forKey:@"touchVisible"]; else [defaults removeObjectForKey:@"touchVisible"];
    if (savedMode) [defaults setObject:savedMode forKey:@"tiltMode"]; else [defaults removeObjectForKey:@"tiltMode"];
    [self updateControlVisibility]; [self viewDidLayoutSubviews];
    win32::platform::log("NFS3_CONTROLS_UI_DIAGNOSTIC: PASS OSD-dependent Back, drawn toggles, mode 1 auto-throttle/screen brake keyboard events, mode 2 visible manual pedals/no auto-throttle, mode persistence, automatic gears/police gating and pause releases motion/pedals");
}
- (void)diagnostic
{
    if (_busy || _playing) return;
    if (!_logSwitch.on) { _logSwitch.on = YES; [self settingsChanged]; }
    _busy = YES;
    _launcher.hidden = YES;
    nfsios::inputDiagnostic();
    nfsios::hapticsDiagnostic();
    NFSSetHapticsEnabled(_vibrationSwitch.on);
    NFSKeyboardDiagnostic();
    [self automaticKeyboardDiagnostic];
    [self lifecycleDiagnostic];
    NFSLayoutEditorDiagnostic();
    for (unsigned session = 0; session < 2; ++session) NFSPointerDiagnostic();
    [self controlVisibilityDiagnostic];
    BOOL previousOSD = _osdSwitch.on;
    _osdSwitch.on = YES;
    _controls.hidden = NO;
    [self arrangeControls];
    [self arrangeOSD];
    for (NFSKeyButton* button in _keys)
        NFS2_ASSERT(!CGRectIntersectsRect(_osd.frame, CGRectInset(button.frame, -6, -6)));
    NFS2_ASSERT([self.view hitTest:[self.view convertPoint:CGPointMake(CGRectGetMidX(_pointer.bounds), CGRectGetMidY(_pointer.bounds)) fromView:_pointer] withEvent:nil] == _pointer);
    _controls.hidden = YES;
    _osdSwitch.on = previousOSD;
    [self arrangeControls];
    win32::platform::log("NFS3_LAYOUT_DIAGNOSTIC: PASS OSD avoids all fourteen controls; game screen receives hits through overlay");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block BOOL audio = NO;
        @autoreleasepool {
            nfsios::filesystemDiagnostic();
            nfsios::gameInputDiagnostic();
            nfsios::forceFeedbackDiagnostic();
            nfsios::timerDiagnostic();
            nfsios::graphicsDiagnostic();
            nfsios::graphicsIntegrationDiagnostic();
            nfsios::graphicsConcurrencyDiagnostic();
            nfsios::graphicsAllocationDiagnostic();
            audio = nfsios::audioDiagnostic();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            self->_launcher.hidden = NO;
            self->_status.text = audio
                ? @"测试通过：显示、声音与输入。"
                : @"显示与输入通过；音频输出未检测到，请查看日志。";
        });
    });
}
- (void)dealloc
{
    [_displayLink invalidate];
    [_motion stopDeviceMotionUpdates];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    nfsios::stopGame();
    if (_worker.joinable()) _worker.join();
}
@end
namespace nfsios
{
void filesystemDiagnostic()
{
    @autoreleasepool
    {
        NSFileManager* manager = NSFileManager.defaultManager;
        NSString* root = [documentsPath() stringByAppendingPathComponent:[@"NativeFileFixture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString* assets = [root stringByAppendingPathComponent:@"Assets"];
        NFS2_ASSERT([manager createDirectoryAtPath:assets withIntermediateDirectories:YES attributes:nil error:nil]);
        NFS2_ASSERT(prepareGameDirectory(root, nullptr) && !directoryContainsGame(root));
        for (NSString* folder in @[@"FeData", @"GameData"])
            NFS2_ASSERT([manager createDirectoryAtPath:[root stringByAppendingPathComponent:folder] withIntermediateDirectories:YES attributes:nil error:nil]);
        NFS2_ASSERT(directoryContainsGame(root));
        NFS2_ASSERT(prepareGameDirectory(root, nullptr));
        for (NSString* name in @[@"nfs3.exe", @"eacsnd.dll", @"softtria.dll", @"voodoo2a.dll", @"install.win"])
        {
            NSData* bundled = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[@"GameFiles" stringByAppendingPathComponent:name]]];
            NSData* copied = [NSData dataWithContentsOfFile:caseMatchedPath(root, name)];
            NFS2_ASSERT(bundled.length && [bundled isEqualToData:copied]);
        }
        NSString* manifest = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"install.win"] encoding:NSASCIIStringEncoding error:nil];
        NSMutableArray* paths = [[manifest componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] mutableCopy];
        while ([paths.lastObject isEqualToString:@""]) [paths removeLastObject];
        NFS2_ASSERT(paths.count == 40 && [paths[0] isEqualToString:@"english"]);
        NFS2_ASSERT([paths[3] isEqualToString:@"gamedata\\tracks\\"] && [paths[25] isEqualToString:@"fedata\\movies\\"]);
        NSString* profile = caseMatchedPath(root, @"fedata/save/Profile.dat");
        NFS2_ASSERT([[@"profile" dataUsingEncoding:NSASCIIStringEncoding] writeToFile:profile atomically:YES]);
        NFS2_ASSERT(prepareGameDirectory(root, nullptr));
        NFS2_ASSERT([[NSString stringWithContentsOfFile:profile encoding:NSASCIIStringEncoding error:nil] isEqualToString:@"profile"]);
        for (NSString* folder in @[@"FeData", @"GameData"])
            NFS2_ASSERT([manager removeItemAtPath:[root stringByAppendingPathComponent:folder] error:nil]);
        NSString* nested = [root stringByAppendingPathComponent:@"NFS3"];
        for (NSString* folder in @[@"FEDATA", @"GAMEDATA"])
            NFS2_ASSERT([manager createDirectoryAtPath:[nested stringByAppendingPathComponent:folder] withIntermediateDirectories:YES attributes:nil error:nil]);
        NFS2_ASSERT(directoryContainsGame(nested) && !directoryContainsGame(root));
        NFS2_ASSERT(prepareGameDirectory(nested, nullptr));
        NSString* legacy = [root stringByAppendingPathComponent:@"GameDataRoot"];
        NFS2_ASSERT([manager moveItemAtPath:nested toPath:legacy error:nil]);
        NFS2_ASSERT(directoryContainsGame(legacy));
        nfsios::drivingModeDiagnostic(legacy.fileSystemRepresentation);
        win32::platform::log("NFS3_DATA_DIAGNOSTIC: PASS five bundled files, 40-slot install.win, explicit data root and save preservation without automatic migration");
        NSData* seed = [@"native" dataUsingEncoding:NSASCIIStringEncoding];
        NFS2_ASSERT([seed writeToFile:[assets stringByAppendingPathComponent:@"Menu.BIN"] atomically:YES]);
        win32::File::setDataDirectory(root.fileSystemRepresentation);
        win32::File::setCdDirectory(root.fileSystemRepresentation);
        {
            nfs3hp::Application game("nfs3.exe");
            x86::CPU cpu{};
            NFS2_ASSERT(game.runThread(cpu, 0x4a6e10) == 1);
            NFS2_ASSERT(strcmp(&game.getMemory<char>(0x7a2634), "english") == 0);
            NFS2_ASSERT(strcmp(&game.getMemory<char>(0x7a2634 + 3 * 128), "gamedata\\tracks\\") == 0);
            NFS2_ASSERT(strcmp(&game.getMemory<char>(0x7a2634 + 25 * 128), "fedata\\movies\\") == 0);
            win32::platform::log("NFS3_INSTALL_DIAGNOSTIC: PASS generated install.win accepted by original guest parser");
        }
        {
            win32::File resource("assets\\menu.bin", win32::GENERIC_READ, 0, win32::OPEN_EXISTING);
            char bytes[6]{};
            uint32_t count = 0;
            NFS2_ASSERT(resource.read(bytes, sizeof(bytes), &count) && count == sizeof(bytes));
            NFS2_ASSERT(memcmp(bytes, "native", sizeof(bytes)) == 0);
        }
        {
            win32::FileEnumerator files("ASSETS\\*.bin");
            win32::WIN32_FIND_DATAA found{};
            NFS2_ASSERT(files.findNext(&found) && strcasecmp(found.cFileName, "Menu.BIN") == 0);
        }
        {
            win32::File save("Saved.Profile", win32::GENERIC_WRITE, 0, win32::CREATE_ALWAYS);
            uint32_t count = 0;
            NFS2_ASSERT(save.write("saved", 5, &count) && count == 5);
        }
        {
            win32::File saved("saved.profile", win32::GENERIC_READ, 0, win32::OPEN_EXISTING);
            char bytes[5]{};
            uint32_t count = 0;
            NFS2_ASSERT(saved.read(bytes, sizeof(bytes), &count) && count == sizeof(bytes));
            NFS2_ASSERT(memcmp(bytes, "saved", sizeof(bytes)) == 0);
        }
        NFS2_ASSERT(win32::File::remove("SAVED.PROFILE") == 1);
        NFS2_ASSERT([manager removeItemAtPath:root error:nil]);
        win32::platform::log("NATIVE_FILE_DIAGNOSTIC: PASS mixed-case resource reads, enumeration, save writes and deletion");
    }
}
}

@interface NFSAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation NFSAppDelegate
- (UIInterfaceOrientationMask)application:(UIApplication*)application supportedInterfaceOrientationsForWindow:(UIWindow*)window
{
    (void)application; (void)window;
    return window.rootViewController ? window.rootViewController.supportedInterfaceOrientations : UIInterfaceOrientationMaskLandscape;
}
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options
{
    (void)application; (void)options;
    return YES;
}
@end

@interface NFSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation NFSSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options
{
    (void)session; (void)options;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = [NFSViewController new];
    ((NFSAppDelegate*)UIApplication.sharedApplication.delegate).window = self.window;
    [self.window makeKeyAndVisible];
    if (@available(iOS 16.0, *))
    {
        if (self.window.rootViewController.supportedInterfaceOrientations == UIInterfaceOrientationMaskLandscape)
        {
            UIWindowSceneGeometryPreferencesIOS* geometry = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
            [(UIWindowScene*)scene requestGeometryUpdateWithPreferences:geometry errorHandler:^(NSError* error) { NSLog(@"Orientation: %@", error); }];
        }
    }
}
- (void)sceneDidBecomeActive:(UIScene*)scene
{
    (void)scene;
    [(NFSViewController*)self.window.rootViewController foreground];
}
- (void)sceneWillResignActive:(UIScene*)scene
{
    (void)scene;
    [(NFSViewController*)self.window.rootViewController background];
}
@end
namespace win32::platform
{
void showMessage(const char* title, const char* text)
{
    NSString* caption = [NSString stringWithUTF8String:title ? title : "NFS III"];
    NSString* message = [NSString stringWithUTF8String:text ? text : ""];
    log("Game message: %s: %s", title ? title : "", text ? text : "");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* window = ((NFSAppDelegate*)UIApplication.sharedApplication.delegate).window;
        UIViewController* controller = window.rootViewController;
        if (controller.presentedViewController) return;
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:caption message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}
}
int main(int argc, char* argv[])
{
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NFSAppDelegate.class)); }
}
