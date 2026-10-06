#import <UIKit/UIKit.h>
@interface SBCPUChargeHistoryController : UITableViewController @end
@implementation SBCPUChargeHistoryController { NSArray *_records; }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"充电历史"; self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)]; [self loadRecords]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self loadRecords]; [self.tableView reloadData]; }
- (void)loadRecords { NSData *d=[NSData dataWithContentsOfFile:@"/var/mobile/Library/Preferences/com.sbcpu.floating.charge-sessions.json"]; id v=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil; _records=[v isKindOfClass:[NSArray class]]?v:@[]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return MAX(1,(NSInteger)_records.count); }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p { UITableViewCell *c=[t dequeueReusableCellWithIdentifier:@"h"]?:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"h"]; if (!_records.count) { c.textLabel.text=@"暂无充电记录"; c.detailTextLabel.text=@"插入充电器后会自动记录"; return c; } NSDictionary *x=_records[p.row]; c.textLabel.text=[NSString stringWithFormat:@"%ld%% → %ld%%",[x[@"startPercent"] integerValue],[x[@"endPercent"] integerValue]]; c.detailTextLabel.text=[NSString stringWithFormat:@"充入 %.0f mAh · 峰值 %.1f W",[x[@"batteryMah"] doubleValue],[x[@"peakInputW"] doubleValue]]; return c; }
- (void)clearAll { [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Preferences/com.sbcpu.floating.charge-sessions.json" error:nil]; [self loadRecords]; [self.tableView reloadData]; }
@end
