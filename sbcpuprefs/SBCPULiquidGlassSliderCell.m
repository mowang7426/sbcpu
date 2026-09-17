#import "SBCPULiquidGlassSliderCell.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "SBCPUChargePreferencesCommon.h"

@interface SBCPULiquidGlassSliderCell ()
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *valueLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UISlider *slider;
@property(nonatomic,strong) PSSpecifier *lgSpecifier;
@end

@implementation SBCPULiquidGlassSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) return nil;

    _lgSpecifier = specifier;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.contentView.clipsToBounds = NO;

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.backgroundColor = UIColor.clearColor;
    _nameLabel.text = [specifier propertyForKey:@"label"] ?: @"参数";
    [self.contentView addSubview:_nameLabel];

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightMedium];
    _valueLabel.textColor = UIColor.secondaryLabelColor;
    _valueLabel.backgroundColor = UIColor.clearColor;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_valueLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.backgroundColor = UIColor.clearColor;
    _detailLabel.numberOfLines = 2;
    _detailLabel.text = [specifier propertyForKey:@"description"] ?: @"";
    [self.contentView addSubview:_detailLabel];

    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    _slider.minimumValue = [[specifier propertyForKey:@"min"] floatValue];
    _slider.maximumValue = [[specifier propertyForKey:@"max"] floatValue];
    _slider.continuous = YES;
    _slider.minimumTrackTintColor = nil; // system tint
    _slider.maximumTrackTintColor = nil;
    [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_slider];

    [self reloadValue];
    [self setNeedsLayout];
    return self;
}

/*
 * Preferences can ask a custom PSTableCell for its height. Keep this explicit
 * instead of relying only on the plist "height" key.
 */
- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return 104.0;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return 104.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect b = self.contentView.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = CGRectGetHeight(b);

    // Some Preferences versions temporarily give contentView a stale/short
    // frame during the first layout pass. Do not put the slider below that
    // frame; keep the whole control group inside the actual cell bounds.
    CGFloat pad = 18.0;
    CGFloat top = 8.0;
    CGFloat valueW = 70.0;
    CGFloat labelW = MAX(40.0, w - pad * 2.0 - valueW);

    self.nameLabel.frame = CGRectMake(pad, top, labelW, 22.0);
    self.valueLabel.frame = CGRectMake(w - pad - valueW, top, valueW, 22.0);

    CGFloat detailY = 30.0;
    CGFloat detailH = MIN(28.0, MAX(18.0, h - 66.0));
    self.detailLabel.frame = CGRectMake(pad, detailY,
                                         MAX(40.0, w - pad * 2.0),
                                         detailH);

    CGFloat sliderY = MAX(52.0, h - 40.0);
    CGFloat sliderH = 30.0;
    // If Preferences reports an unexpectedly short contentView, clamp the
    // slider into the visible area instead of letting it disappear.
    if (h < 90.0) {
        sliderY = MAX(34.0, h - 30.0);
        sliderH = 30.0;
    }
    self.slider.frame = CGRectMake(pad - 4.0, sliderY,
                                   MAX(80.0, w - (pad - 4.0) * 2.0),
                                   sliderH);
    self.slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    _lgSpecifier = specifier;

    self.nameLabel.text = [specifier propertyForKey:@"label"] ?: @"参数";
    self.detailLabel.text = [specifier propertyForKey:@"description"] ?: @"";
    self.slider.minimumValue = [[specifier propertyForKey:@"min"] floatValue];
    self.slider.maximumValue = [[specifier propertyForKey:@"max"] floatValue];

    [self reloadValue];
    [self setNeedsLayout];
}

- (void)reloadValue {
    NSString *key = [self.lgSpecifier propertyForKey:@"key"];
    id def = [self.lgSpecifier propertyForKey:@"default"];
    id value = [SBCPUChargePreferencesCommon valueForKey:key defaultValue:def];

    CGFloat f = [value respondsToSelector:@selector(doubleValue)]
        ? [value doubleValue]
        : [def doubleValue];

    f = MAX(self.slider.minimumValue, MIN(self.slider.maximumValue, f));
    self.slider.value = f;
    self.valueLabel.text = [self displayValue:f key:key];
}

- (NSString *)displayValue:(CGFloat)value key:(NSString *)key {
    if ([key isEqualToString:@"SBCPU.LiquidGlass.RefractiveIndex"] ||
        [key isEqualToString:@"SBCPU.LiquidGlass.Bezel"]) {
        return [NSString stringWithFormat:@"%.2f", value];
    }

    return [NSString stringWithFormat:@"%.0f%%", value * 100.0];
}

- (void)sliderChanged:(UISlider *)slider {
    NSString *key = [self.lgSpecifier propertyForKey:@"key"];
    NSNumber *value = @(slider.value);

    [SBCPUChargePreferencesCommon setValue:value forKey:key];
    self.valueLabel.text = [self displayValue:slider.value key:key];
}

@end
