#import "LayoutEditor.h"
#import "TouchUI.h"
#include <lib/platform.h>
#include <x86.h>
#include <cmath>

@interface NFSLayoutGrid : NFSControlSurface
@property(nonatomic) CGFloat step;
@end

@implementation NFSLayoutGrid
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
        self.backgroundColor = [UIColor colorWithRed:0.047 green:0.063 blue:0.09 alpha:1];
    return self;
}
- (void)drawRect:(CGRect)rect
{
    if (self.step <= 0) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(context, 0.5);
    for (unsigned axis = 0; axis < 2; ++axis)
    {
        CGFloat extent = axis ? rect.size.height : rect.size.width;
        for (unsigned index = 0; index * self.step <= extent; ++index)
        {
            CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:index % 4 ? 0.06 : 0.14].CGColor);
            CGFloat coordinate = index * self.step;
            CGContextMoveToPoint(context, axis ? 0 : coordinate, axis ? coordinate : 0);
            CGContextAddLineToPoint(context, axis ? rect.size.width : coordinate, axis ? coordinate : rect.size.height);
            CGContextStrokePath(context);
        }
    }
}
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    UIView* control = [super hitTest:point withEvent:event];
    if (control) return control;
    return !self.hidden && self.userInteractionEnabled && self.alpha > 0.01 && [self pointInside:point withEvent:event] ? self : nil;
}
@end

@interface NFSLayoutEditorController () <UIGestureRecognizerDelegate>
@end

@implementation NFSLayoutEditorController
{
    CGSize _referenceSize;
    CGFloat _pixel;
    CGFloat _header;
    CGFloat _previewScale;
    CGFloat _layoutScale;
    void (^_completion)(void);
    NSMutableDictionary* _layout;
    NSArray<NSString*>* _symbols;
    NSArray<NSString*>* _labels;
    NSMutableArray<NFSSymbolButton*>* _buttons;
    NSArray<NSValue*>* _baseFrames;
    NFSSymbolButton* _selection;
    UIView* _card;
    NFSLayoutGrid* _grid;
    UILabel* _selectionLabel;
    UILabel* _sizeLabel;
    UISlider* _sizeSlider;
    UISwitch* _snapSwitch;
    CGPoint _dragStart;
}
- (instancetype)initWithReferenceSize:(CGSize)size pixel:(CGFloat)pixel header:(CGFloat)header completion:(void (^)(void))completion
{
    if ((self = [super initWithNibName:nil bundle:nil]))
    {
        _referenceSize = size;
        _pixel = pixel;
        _header = header;
        _completion = [completion copy];
        _layout = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"symbolLayout"] mutableCopy] ?: [NSMutableDictionary dictionary];
        _symbols = @[@"left", @"right", @"accelerate", @"brake", @"handbrake", @"pause", @"gear_up", @"gear_down", @"camera", @"horn", @"recover", @"look_behind", @"spike_strip", @"headlights"];
        _labels = @[NSLocalizedString(@"Steer left", @""), NSLocalizedString(@"Steer right", @""), NSLocalizedString(@"Accelerate", @""), NSLocalizedString(@"Brake", @""), NSLocalizedString(@"Handbrake", @""), NSLocalizedString(@"Pause", @""), NSLocalizedString(@"Gear up", @""), NSLocalizedString(@"Gear down", @""), NSLocalizedString(@"Camera", @""), NSLocalizedString(@"Horn", @""), NSLocalizedString(@"Recover", @""), NSLocalizedString(@"Look behind", @""), NSLocalizedString(@"Spike strip", @""), NSLocalizedString(@"Headlights", @"")];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}
- (UIButton*)button:(NSString*)title action:(SEL)action
{
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    button.layer.cornerRadius = 8;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:72].active = YES;
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    return button;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.035 blue:0.055 alpha:1];
    _selectionLabel = [UILabel new];
    _selectionLabel.textColor = [UIColor colorWithRed:1 green:0.75 blue:0.42 alpha:1];
    _selectionLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _selectionLabel.adjustsFontSizeToFitWidth = YES;
    _selectionLabel.minimumScaleFactor = 0.8;
    [_selectionLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    _snapSwitch = [UISwitch new];
    id preference = [NSUserDefaults.standardUserDefaults objectForKey:@"touchSnap"];
    _snapSwitch.on = preference ? [preference boolValue] : YES;
    _snapSwitch.accessibilityLabel = NSLocalizedString(@"Snap to grid", @"");
    [_snapSwitch addTarget:self action:@selector(snapChanged) forControlEvents:UIControlEventValueChanged];
    UILabel* snapLabel = [UILabel new];
    snapLabel.text = NSLocalizedString(@"Snap", @"");
    snapLabel.font = [UIFont systemFontOfSize:14];
    snapLabel.textColor = UIColor.whiteColor;
    UIStackView* toolbar = [[UIStackView alloc] initWithArrangedSubviews:@[[self button:NSLocalizedString(@"Done", @"") action:@selector(done)], _selectionLabel, snapLabel, _snapSwitch, [self button:NSLocalizedString(@"Reset", @"") action:@selector(confirmReset)]]];
    toolbar.axis = UILayoutConstraintAxisHorizontal;
    toolbar.spacing = 12;
    toolbar.alignment = UIStackViewAlignmentCenter;
    _card = [UIView new];
    _card.backgroundColor = [UIColor colorWithWhite:0.015 alpha:1];
    _card.clipsToBounds = YES;
    _grid = [NFSLayoutGrid new];
    [_card addSubview:_grid];
    UITapGestureRecognizer* deselect = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(deselect:)];
    deselect.delegate = self;
    [_grid addGestureRecognizer:deselect];
    _buttons = [NSMutableArray array];
    for (unsigned index = 0; index < _symbols.count; ++index)
    {
        NFSSymbolButton* button = [[NFSSymbolButton alloc] initWithFrame:CGRectZero];
        button.symbol = _symbols[index];
        button.accessibilityLabel = _labels[index];
        button.tag = index;
        [button addTarget:self action:@selector(selectControl:) forControlEvents:UIControlEventTouchDown];
        UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragControl:)];
        pan.maximumNumberOfTouches = 1;
        [button addGestureRecognizer:pan];
        [_grid addSubview:button];
        [_buttons addObject:button];
    }
    _sizeLabel = [UILabel new];
    _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    _sizeLabel.textColor = UIColor.whiteColor;
    [_sizeLabel.widthAnchor constraintEqualToConstant:92].active = YES;
    _sizeSlider = [UISlider new];
    _sizeSlider.minimumValue = 50;
    _sizeSlider.maximumValue = 180;
    _sizeSlider.accessibilityLabel = NSLocalizedString(@"Button size", @"");
    [_sizeSlider addTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView* footer = [[UIStackView alloc] initWithArrangedSubviews:@[_sizeLabel, _sizeSlider]];
    footer.spacing = 12;
    footer.alignment = UIStackViewAlignmentCenter;
    for (UIView* element in @[toolbar, _card, footer])
    {
        element.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:element];
    }
    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [toolbar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [toolbar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [toolbar.heightAnchor constraintEqualToConstant:44],
        [_card.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:8],
        [_card.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_card.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_card.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-8],
        [footer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [footer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [footer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [footer.heightAnchor constraintEqualToConstant:44]]];
    [self syncSelection];
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (_card.bounds.size.width <= 0 || _card.bounds.size.height <= 0) return;
    _previewScale = MIN(_card.bounds.size.width / _referenceSize.width, _card.bounds.size.height / _referenceSize.height);
    _layoutScale = NFSControlLayoutScale(_referenceSize, _header);
    _grid.frame = CGRectMake((_card.bounds.size.width - _referenceSize.width * _previewScale) / 2, (_card.bounds.size.height - _referenceSize.height * _previewScale) / 2, _referenceSize.width * _previewScale, _referenceSize.height * _previewScale);
    _grid.step = 8 * _layoutScale * _previewScale;
    [_grid setNeedsDisplay];
    _baseFrames = NFSDefaultControlFrames(CGRectMake(0, 0, _referenceSize.width, _referenceSize.height), _pixel, _header);
    for (NFSSymbolButton* button in _buttons) [self arrangeButton:button];
}
- (CGRect)referenceArea { return CGRectMake(0, 0, _referenceSize.width, _referenceSize.height); }
- (CGRect)referenceFrame:(NFSSymbolButton*)button
{
    return CGRectMake(button.frame.origin.x / _previewScale, button.frame.origin.y / _previewScale, button.frame.size.width / _previewScale, button.frame.size.height / _previewScale);
}
- (void)arrangeButton:(NFSSymbolButton*)button
{
    CGRect frame = NFSResolveControlFrame(_baseFrames[button.tag].CGRectValue, [self referenceArea], _layoutScale, _layout[button.symbol]);
    button.frame = CGRectMake(frame.origin.x * _previewScale, frame.origin.y * _previewScale, frame.size.width * _previewScale, frame.size.height * _previewScale);
}
- (void)selectControl:(NFSSymbolButton*)button
{
    _selection.selected = NO;
    _selection = button;
    _selection.selected = YES;
    [self syncSelection];
}
- (void)syncSelection
{
    _selectionLabel.text = _selection ? _labels[_selection.tag] : NSLocalizedString(@"Select a control", @"");
    _sizeSlider.enabled = _selection != nil;
    NSArray* values = _selection ? _layout[_selection.symbol] : nil;
    _sizeSlider.value = values.count >= 3 ? [values[2] floatValue] * 100 : 100;
    _sizeLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Size %d%%", @""), int(std::lround(_sizeSlider.value))];
}
- (void)deselect:(UITapGestureRecognizer*)gesture { (void)gesture; [self selectControl:nil]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture shouldReceiveTouch:(UITouch*)touch
{
    (void)gesture;
    return touch.view == _grid;
}
- (void)persist
{
    if (_layout.count) [NSUserDefaults.standardUserDefaults setObject:_layout forKey:@"symbolLayout"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"symbolLayout"];
}
- (void)storeFrame:(CGRect)frame forButton:(NFSSymbolButton*)button size:(CGFloat)size
{
    _layout[button.symbol] = NFSEncodeControlFrame(frame, [self referenceArea], _layoutScale, size);
    [self arrangeButton:button];
}
- (void)moveButton:(NFSSymbolButton*)button toCenter:(CGPoint)center
{
    CGRect frame = [self referenceFrame:button];
    if (_snapSwitch.on)
    {
        CGFloat step = 8 * _layoutScale;
        center.x = std::round(center.x / step) * step;
        center.y = std::round(center.y / step) * step;
    }
    frame.origin = CGPointMake(center.x - frame.size.width / 2, center.y - frame.size.height / 2);
    NSArray* values = _layout[button.symbol];
    CGFloat size = values.count >= 3 ? [values[2] doubleValue] : 1;
    [self storeFrame:frame forButton:button size:size];
}
- (void)dragControl:(UIPanGestureRecognizer*)gesture
{
    NFSSymbolButton* button = (NFSSymbolButton*)gesture.view;
    if (gesture.state == UIGestureRecognizerStateBegan)
    {
        [self selectControl:button];
        _dragStart = CGPointMake(button.center.x / _previewScale, button.center.y / _previewScale);
    }
    CGPoint translation = [gesture translationInView:_grid];
    [self moveButton:button toCenter:CGPointMake(_dragStart.x + translation.x / _previewScale, _dragStart.y + translation.y / _previewScale)];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) [self persist];
}
- (void)sizeChanged:(UISlider*)slider
{
    if (!_selection) return;
    CGFloat size = std::round(slider.value) / 100;
    CGRect base = _baseFrames[_selection.tag].CGRectValue;
    CGRect old = [self referenceFrame:_selection];
    CGRect frame = CGRectMake(CGRectGetMidX(old) - base.size.width * size / 2, CGRectGetMidY(old) - base.size.height * size / 2, base.size.width * size, base.size.height * size);
    [self storeFrame:frame forButton:_selection size:size];
    [self persist];
    [self syncSelection];
}
- (void)snapChanged { [NSUserDefaults.standardUserDefaults setBool:_snapSwitch.on forKey:@"touchSnap"]; }
- (void)confirmReset
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Reset layout?", @"") message:NSLocalizedString(@"Restore all controls to their default positions and sizes.", @"") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Reset", @"") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*) { [self resetLayout]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)resetLayout
{
    [_layout removeAllObjects];
    [self persist];
    [self selectControl:nil];
    for (NFSSymbolButton* button in _buttons) [self arrangeButton:button];
}
- (void)done
{
    [self persist];
    [self dismissViewControllerAnimated:YES completion:_completion];
}
- (void)diagnostic
{
    NFS2_ASSERT(!_sizeSlider.enabled && _sizeSlider.minimumValue == 50 && _sizeSlider.maximumValue == 180);
    NFSSymbolButton* button = _buttons[2];
    [self selectControl:button];
    NFS2_ASSERT(_sizeSlider.enabled && button.selected);
    for (float percent : {50, 180, 125})
    {
        _sizeSlider.value = percent;
        [_sizeSlider sendActionsForControlEvents:UIControlEventValueChanged];
        CGRect actual = [self referenceFrame:button];
        CGRect base = _baseFrames[button.tag].CGRectValue;
        NFS2_ASSERT(std::abs(actual.size.width - base.size.width * percent / 100) < 0.01);
        NFS2_ASSERT(std::abs(actual.size.height - base.size.height * percent / 100) < 0.01);
        CGPoint center = CGPointMake(CGRectGetMidX(actual) * _previewScale, CGRectGetMidY(actual) * _previewScale);
        NFS2_ASSERT([_grid hitTest:center withEvent:nil] == button);
    }
    _snapSwitch.on = YES;
    [self moveButton:button toCenter:CGPointMake(323.5 * _layoutScale, 163.1 * _layoutScale)];
    CGRect snapped = [self referenceFrame:button];
    NFS2_ASSERT(std::abs(CGRectGetMidX(snapped) / _layoutScale - 320) < 0.01 && std::abs(CGRectGetMidY(snapped) / _layoutScale - 160) < 0.01);
    _snapSwitch.on = NO;
    [self moveButton:button toCenter:CGPointMake(333.5 * _layoutScale, 173.1 * _layoutScale)];
    CGRect free = [self referenceFrame:button];
    NFS2_ASSERT(std::abs(CGRectGetMidX(free) / _layoutScale - 333.5) < 0.01);
    [self moveButton:button toCenter:CGPointMake(-1000, 1000)];
    CGRect clipped = [self referenceFrame:button];
    NFS2_ASSERT(CGRectContainsRect([self referenceArea], clipped));
    [self persist];
    NSArray* stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"symbolLayout"][button.symbol];
    CGRect game = NFSResolveControlFrame(_baseFrames[button.tag].CGRectValue, [self referenceArea], _layoutScale, stored);
    NFS2_ASSERT(std::abs(game.origin.x - clipped.origin.x) < 0.01 && std::abs(game.origin.y - clipped.origin.y) < 0.01);
    CGRect largerArea = CGRectMake(0, 0, _referenceSize.width + 120, _referenceSize.height + 80);
    CGRect anchored = NFSResolveControlFrame(_baseFrames[button.tag].CGRectValue, largerArea, _layoutScale, stored);
    NFS2_ASSERT(std::abs(CGRectGetMaxY(largerArea) - CGRectGetMidY(anchored) - (CGRectGetMaxY([self referenceArea]) - CGRectGetMidY(clipped))) < 0.01);
    [self resetLayout];
    NFS2_ASSERT(!_selection && !_sizeSlider.enabled && _layout.count == 0);
}
@end

void NFSLayoutEditorDiagnostic()
{
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"symbolLayout"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"symbolLayout"];
    for (NSValue* reference in @[[NSValue valueWithCGSize:CGSizeMake(736, 414)], [NSValue valueWithCGSize:CGSizeMake(1194, 834)]])
    {
        NFSLayoutEditorController* editor = [[NFSLayoutEditorController alloc] initWithReferenceSize:reference.CGSizeValue pixel:1 / UIScreen.mainScreen.scale header:56 completion:nil];
        [editor loadViewIfNeeded];
        editor.view.frame = CGRectMake(0, 0, 900, 500);
        [editor.view setNeedsLayout];
        [editor.view layoutIfNeeded];
        [editor diagnostic];
    }
    if (saved) [NSUserDefaults.standardUserDefaults setObject:saved forKey:@"symbolLayout"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"symbolLayout"];
    win32::platform::log("NFS3_EDITOR_DIAGNOSTIC: PASS selection, 50..180 percent slider, drawn/hit size agreement, snap/free drag, bounds, edge anchors, persistence, reset and matching game/preview frames");
}
