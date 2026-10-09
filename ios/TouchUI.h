#pragma once
#import <UIKit/UIKit.h>

@interface NFSSymbolButton : UIButton
@property(nonatomic, copy) NSString* symbol;
@property(nonatomic) BOOL active;
@end

@interface NFSControlSurface : UIView
@end

@interface NFSGameInputView : UIView <UIKeyInput, UITextFieldDelegate>
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL brakeEnabled;
@property(nonatomic, readonly) BOOL braking;
- (void)cancelPointer;
@end

NSArray<NSValue*>* NFSDefaultControlFrames(CGRect area, CGFloat pixel, CGFloat header = 0);
CGFloat NFSControlLayoutScale(CGSize size, CGFloat header);
CGRect NFSConstrainControlFrame(CGRect frame, CGRect area);
CGRect NFSResolveControlFrame(CGRect base, CGRect area, CGFloat scale, NSArray* values);
NSArray* NFSEncodeControlFrame(CGRect frame, CGRect area, CGFloat scale, CGFloat size);
void NFSKeyboardDiagnostic();
void NFSPointerDiagnostic();
void NFSBrakeDiagnostic();
void NFSSetHapticsEnabled(BOOL enabled);
void NFSTouchFeedback();
