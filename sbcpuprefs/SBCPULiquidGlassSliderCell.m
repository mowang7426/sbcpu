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

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) return nil;

    _lgSpecifier = specifier;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    _nameLabel = [UILabel new];
    _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _nameLabel.textColor = UIColor.labelColor;
    [self.contentView addSubview:_nameLabel];

    _valueLabel = [UILabel new];
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    _valueLabel.textColor = UIColor.secondaryLabelColor;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_valueLabel];

    _detailLabel = [UILabel new];
    _detailLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 2;
    [self.contentView addSubview:_detailLabel];

    _slider = [UISlider new];
    _slider.minimumValue = [[specifier propertyForKey:@"min"] floatValue];
    _slider.maximumValue = [[specifier propertyForKey:@"max"] floatValue];
    [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_slider];

    _nameLabel.text = [specifier propertyForKey:@"label"] ?: @"参数";
    _detailLabel.text = [specifier propertyForKey:@"description"] ?: @"";
    [self reloadValue];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.contentView.bounds);
    CGFloat h = CGRectGetHeight(self.contentView.bounds);
    CGFloat pad = 18.0;
    CGFloat valueW = 72.0;
    CGFloat top = 8.0;

    self.nameLabel.frame = CGRectMake(pad, top, w - pad * 2 - valueW, 21.0);
    self.valueLabel.frame = CGRectMake(w - pad - valueW, top, valueW, 21.0);
    self.detailLabel.frame = CGRectMake(pad, top + 22.0, w - pad * 2, 30.0);
    self.slider.frame = CGRectMake(pad - 3.0, MAX(58.0, h - 40.0), w - (pad - 3.0) * 2.0, 28.0);
}

- (void)reloadValue {
    NSString *key = [self.lgSpecifier propertyForKey:@"key"];
    id def = [self.lgSpecifier propertyForKey:@"default"];
    id value = [SBCPUChargePreferencesCommon valueForKey:key defaultValue:def];
    CGFloat f = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : [def doubleValue];
    f = MAX(self.slider.minimumValue, MIN(self.slider.maximumValue, f));
    self.slider.value = f;
    self.valueLabel.text = [self displayValue:f key:key];
}

- (NSString *)displayValue:(CGFloat)value key:(NSString *)key {
    if ([key isEqualToString:@"SBCPU.LiquidGlass.RefractiveIndex"]) {
        return [NSString stringWithFormat:@"%.2f", value];
    }
    if ([key isEqualToString:@"SBCPU.LiquidGlass.Bezel"]) {
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

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return 112.0;
}

@end
