#import "SBCPULiquidGlassSliderCell.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "SBCPUChargePreferencesCommon.h"

@interface SBCPULiquidGlassSliderCell ()
@property(nonatomic,strong) UILabel *valueLabel;
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

    // The standard PSTableCell already renders the plist's label + description.
    // Do not create another title/description pair here, otherwise every slider
    // item is shown twice.
    if (self.textLabel) {
        self.textLabel.hidden = NO;
    }
    if (self.detailTextLabel) {
        self.detailTextLabel.hidden = NO;
        self.detailTextLabel.numberOfLines = 2;
    }

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightMedium];
    _valueLabel.textColor = UIColor.secondaryLabelColor;
    _valueLabel.backgroundColor = UIColor.clearColor;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_valueLabel];

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

    CGFloat pad = 18.0;
    CGFloat valueW = 70.0;

    // Keep the value aligned with the built-in PSTableCell title row.
    self.valueLabel.frame = CGRectMake(w - pad - valueW, 8.0, valueW, 22.0);

    CGFloat sliderY = MAX(52.0, h - 40.0);
    CGFloat sliderH = 30.0;
    if (h < 90.0) {
        sliderY = MAX(34.0, h - 30.0);
    }
    self.slider.frame = CGRectMake(pad - 4.0, sliderY,
                                   MAX(80.0, w - (pad - 4.0) * 2.0),
                                   sliderH);
    self.slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    _lgSpecifier = specifier;

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

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self reloadValue];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self reloadValue];
}
