#pragma once
#import <UIKit/UIKit.h>

@interface NFSLayoutEditorController : UIViewController
- (instancetype)initWithReferenceSize:(CGSize)size pixel:(CGFloat)pixel header:(CGFloat)header completion:(void (^)(void))completion;
@end

void NFSLayoutEditorDiagnostic();
