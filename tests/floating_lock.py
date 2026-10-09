from pathlib import Path
s = (Path(__file__).resolve().parents[1] / 'Tweak.xm').read_text()
def method(name, following):
    return s[s.index(name):s.index(following, s.index(name))]
assert 'self.doubleTapGesture.numberOfTapsRequired = 2;' in s
assert '[self.singleTapGesture requireGestureRecognizerToFail:self.doubleTapGesture];' in s
begin = method('- (BOOL)gestureRecognizerShouldBegin:', '- (void)handleSingleTap:')
assert 'UIPanGestureRecognizer class' in begin and 'self.positionLocked' in begin
pan = method('- (void)handlePan:', '- (BOOL)gestureRecognizer:')
assert pan.index('if (self.positionLocked) return;') < pan.index('[self resetInactivityTimer]')
toggle = method('- (void)handleDoubleTap:', '- (BOOL)gestureRecognizerShouldBegin:')
for token in ('UIGestureRecognizerStateEnded', 'presentation.position', 'self.positionLocked = YES',
              'self.positionLocked = NO', 'SBCPU.LockedCenter', 'SBCPU.PositionLocked',
              '[feedback impactOccurred]', 'keyboardMoved = NO', 'self.statusDockReturnTimer = nil'):
    assert token in toggle, token
assert '[super setCenter:center]' in method('- (void)setCenter:', '- (void)handleDoubleTap:')
assert 'SBCPULockedCoordinate' in method('- (void)setCenter:', '- (void)handleDoubleTap:')
assert 'if (floatingView.positionLocked || floatingTextOnlyMode' in s
assert 'if (!floatingView.positionLocked && !floatingTextOnlyMode' in s
assert 'if (floatingTextOnlyMode || self.positionLocked) return;' in s
assert '[positionDefaults boolForKey:@"SBCPU.PositionLocked"] && lockedPoint.length' in s
assert 'isfinite(point.x) && isfinite(point.y)' in s
print('floating lock gesture/persistence integration regression passed')
