// ============================================================
//  ACMODDED - Tweak.x.m  (updated with Spawn Loop feature)
//  Adds a UISwitch "Auto Spawn" toggle to the Items tab.
//  When ON it fires _spawnItem() every 1 ms via a repeating
//  NSTimer (clamped to the runloop resolution, ~1 ms).
// ============================================================

#import <UIKit/UIKit.h>
#import <substrate.h>

// ── forward declarations ──────────────────────────────────
void _spawnItem(const char *itemID);
void *_getLocalPlayer(void);
void *_getSpawnPosition(void);
void _saveSettings(void);
void _loadSettings(void);
void _initializeIL2CPP(void);
void _initializeGameClasses(void);
void _initializeLists(void);

// ── globals (kept from original) ─────────────────────────
static int     _selectedItemIndex     = 0;
static int     _spawnQuantity         = 1;
static float   _customSpawnX          = 0.f;
static float   _customSpawnY          = 0.f;
static float   _customSpawnZ          = 0.f;
static BOOL    _useCustomLocation     = NO;
static int     _selectedPresetLocation= 0;
static NSMutableArray *_availableItems  = nil;
static NSMutableArray *_filteredItems   = nil;
static NSArray        *_presetLocations = nil;

static UIViewController *_menuController = nil;
static UIButton         *_menuButton     = nil;
static BOOL              _isInitialized  = NO;

// ── NEW: spawn-loop state ─────────────────────────────────
static NSTimer *_spawnLoopTimer  = nil;
static BOOL     _spawnLoopActive = NO;   // mirrors the switch

// ── helper: fire one spawn from the loop ─────────────────
static void spawnLoopTick(void) {
    if (!_spawnLoopActive) return;
    if (_filteredItems.count == 0)  return;
    if (_selectedItemIndex >= (int)_filteredItems.count) return;

    NSString *itemID = _filteredItems[_selectedItemIndex];
    _spawnItem(itemID.UTF8String);
}

// ── start / stop helpers ─────────────────────────────────
static void startSpawnLoop(void) {
    if (_spawnLoopTimer) return;                          // already running
    _spawnLoopActive = YES;
    // NSTimer minimum resolution is ~1 ms on modern iOS
    _spawnLoopTimer = [NSTimer
        scheduledTimerWithTimeInterval:0.001          // 1 ms
        repeats:YES
        block:^(NSTimer *t){ spawnLoopTick(); }];
    // Put it on the common runloop mode so it fires even during scroll
    [[NSRunLoop mainRunLoop] addTimer:_spawnLoopTimer
                              forMode:NSRunLoopCommonModes];
}

static void stopSpawnLoop(void) {
    _spawnLoopActive = NO;
    [_spawnLoopTimer invalidate];
    _spawnLoopTimer = nil;
}

// ── ModMenuController ─────────────────────────────────────
@interface ModMenuController : UIViewController
    <UIPickerViewDelegate, UIPickerViewDataSource>

@property (nonatomic, strong) UIView        *containerView;
@property (nonatomic, strong) UIScrollView  *contentScrollView;
@property (nonatomic, strong) UIView        *contentView;
@property (nonatomic, strong) UIPickerView  *itemPicker;
@property (nonatomic, strong) UILabel       *quantityLabel;
@property (nonatomic, strong) UIStepper     *quantityStepper;
@property (nonatomic, strong) CAGradientLayer *containerGradient;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, assign) NSInteger      currentTab;

// ── NEW ivar for the auto-spawn switch ──
@property (nonatomic, strong) UISwitch *spawnLoopSwitch;

- (void)viewDidLoad;
- (void)setupUI;
- (void)loadItemsTab;
- (void)loadSettingsTab;
- (void)tabChanged:(UISegmentedControl *)sender;
- (void)spawnSelectedItem;
- (void)quantityChanged:(UIStepper *)sender;
- (void)searchItemsWithTextField:(UITextField *)tf;
- (void)closeMenu;
- (void)openKeyboard;
- (void)giveBigMoney;
- (void)giveAllPlayersBigMoney;
- (void)giveInfAmmo;
- (void)removeShopCooldown;
- (void)openDiscord;
- (void)toggleCustomLocation:(UISwitch *)sender;
- (void)applyLocationSettings;
- (void)applyPresetLocationAuto;
- (void)applyPresetLocation:(id)sender;
- (void)resetLocationSettings;
- (void)updateLocationFromFields;
- (float)floatValueFromFieldTag:(int)tag;

// NEW
- (void)toggleSpawnLoop:(UISwitch *)sender;
@end

@implementation ModMenuController

@synthesize containerView, contentScrollView, contentView,
            itemPicker, quantityLabel, quantityStepper,
            containerGradient, tabControl, currentTab,
            spawnLoopSwitch;

// ── view lifecycle ────────────────────────────────────────
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self.view setModalPresentationStyle:0];
    self.currentTab = 0;
    [self setupUI];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self updateLayoutForOrientation];
}

- (void)updateLayoutForOrientation {
    CGRect b = self.view.bounds;
    self.containerView.frame = b;
    self.containerGradient.frame = b;
    [self layoutSubviewsInContainer];
}

// ── main UI setup ─────────────────────────────────────────
- (void)setupUI {
    // gradient background
    UIView *cv = [[UIView alloc] initWithFrame:self.view.bounds];
    cv.layer.cornerRadius  = 16;
    cv.layer.masksToBounds = YES;
    self.containerView = cv;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.colors = @[
        (id)[[UIColor colorWithRed:0 green:.8 blue:.8 alpha:1] CGColor],
        (id)[[UIColor colorWithRed:1 green:1 blue:1 alpha:1] CGColor]
    ];
    grad.startPoint = CGPointMake(0, 0);
    grad.endPoint   = CGPointMake(1, 1);
    self.containerGradient = grad;
    [cv.layer insertSublayer:grad atIndex:0];
    cv.layer.borderWidth = 1;
    cv.layer.borderColor = [[UIColor colorWithRed:.0 green:.6 blue:.6 alpha:1] CGColor];
    [self.view addSubview:cv];

    // close button
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    closeBtn.frame = CGRectMake(cv.bounds.size.width - 44, 4, 40, 40);
    closeBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [closeBtn addTarget:self action:@selector(closeMenu)
      forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:closeBtn];

    // tab bar
    UISegmentedControl *tabs = [[UISegmentedControl alloc]
        initWithItems:@[@"Items", @"Settings"]];
    tabs.selectedSegmentIndex = 0;
    tabs.selectedSegmentTintColor = [UIColor colorWithWhite:.9 alpha:1];
    [tabs setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor blackColor]}
                        forState:UIControlStateSelected];
    [tabs addTarget:self action:@selector(tabChanged:)
   forControlEvents:UIControlEventValueChanged];
    self.tabControl = tabs;
    [cv addSubview:tabs];

    // scroll + content
    UIScrollView *sv = [[UIScrollView alloc] init];
    sv.showsVerticalScrollIndicator = NO;
    sv.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.contentScrollView = sv;
    [cv addSubview:sv];

    UIView *cnt = [[UIView alloc] init];
    cnt.backgroundColor = [UIColor clearColor];
    self.contentView = cnt;
    [sv addSubview:cnt];

    [self layoutSubviewsInContainer];
    [self loadCurrentTab];
}

- (void)layoutSubviewsInContainer {
    CGRect b    = self.containerView.bounds;
    CGFloat pad = 10;
    CGFloat top = 50;

    self.tabControl.frame = CGRectMake(pad, top, b.size.width - pad*2, 34);
    self.contentScrollView.frame = CGRectMake(0, top+44, b.size.width, b.size.height - top - 44);
    self.contentView.frame = CGRectMake(0, 0, b.size.width, self.contentScrollView.frame.size.height);
}

// ── tab switching ─────────────────────────────────────────
- (void)tabChanged:(UISegmentedControl *)sender {
    self.currentTab = sender.selectedSegmentIndex;
    [self loadCurrentTab];
}

- (void)loadCurrentTab {
    for (UIView *v in self.contentView.subviews) [v removeFromSuperview];
    if (self.currentTab == 0)
        [self loadItemsTab];
    else
        [self loadSettingsTab];
}

// ── ITEMS TAB ─────────────────────────────────────────────
- (void)loadItemsTab {
    UIView *cv = self.contentView;
    CGFloat W  = cv.bounds.size.width;
    CGFloat y  = 10;
    CGFloat pad= 12;

    // ── section label
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, W-pad*2, 22)];
    title.text      = @"Item Spawner";
    title.textColor = [UIColor colorWithRed:.0 green:.3 blue:.3 alpha:1];
    title.font      = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [cv addSubview:title];
    y += 28;

    // ── search field
    UITextField *searchTF = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, W-pad*2, 34)];
    searchTF.placeholder     = @"Search items…";
    searchTF.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:.7];
    searchTF.layer.cornerRadius = 8;
    searchTF.keyboardType    = UIKeyboardTypeDefault;
    NSAttributedString *ph   = [[NSAttributedString alloc]
        initWithString:@"Search items…"
            attributes:@{NSForegroundColorAttributeName:[UIColor darkGrayColor]}];
    searchTF.attributedPlaceholder = ph;
    UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(0,0,30,34)];
    searchTF.leftView     = icon;
    searchTF.leftViewMode = UITextFieldViewModeAlways;
    [searchTF addTarget:self action:@selector(searchItemsWithTextField:)
       forControlEvents:UIControlEventEditingChanged];
    [cv addSubview:searchTF];
    y += 40;

    // ── picker
    UIPickerView *pk = [[UIPickerView alloc] initWithFrame:CGRectMake(0, y, W, 150)];
    pk.delegate   = self;
    pk.dataSource = self;
    self.itemPicker = pk;
    [cv addSubview:pk];
    if (_filteredItems.count > 0)
        [pk selectRow:_selectedItemIndex inComponent:0 animated:NO];
    y += 155;

    // ── quantity row
    UILabel *qLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, W/2, 30)];
    qLbl.text      = [NSString stringWithFormat:@"Qty: %d", _spawnQuantity];
    qLbl.textColor = [UIColor darkGrayColor];
    qLbl.font      = [UIFont systemFontOfSize:14];
    self.quantityLabel = qLbl;
    [cv addSubview:qLbl];

    UIStepper *step = [[UIStepper alloc] init];
    step.minimumValue = 1;
    step.maximumValue = 100;
    step.value        = _spawnQuantity;
    step.tintColor    = [UIColor colorWithRed:.0 green:.6 blue:.6 alpha:1];
    step.frame        = CGRectMake(W - 120 - pad, y, 120, 30);
    self.quantityStepper = step;
    [step addTarget:self action:@selector(quantityChanged:)
   forControlEvents:UIControlEventValueChanged];
    [cv addSubview:step];
    y += 36;

    // ── Spawn Once button
    UIButton *spawnBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    spawnBtn.frame     = CGRectMake(pad, y, W - pad*2, 40);
    [spawnBtn setTitle:@"Spawn Item" forState:UIControlStateNormal];
    [spawnBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    spawnBtn.titleLabel.font    = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    spawnBtn.backgroundColor    = [UIColor colorWithRed:.0 green:.55 blue:.55 alpha:1];
    spawnBtn.layer.cornerRadius = 10;
    [spawnBtn addTarget:self action:@selector(spawnSelectedItem)
      forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:spawnBtn];
    y += 48;

    // ── ─────────────────────────────────────────────────
    //   AUTO SPAWN LOOP  (NEW)
    //   Cyan/white pill row with a UISwitch
    // ── ─────────────────────────────────────────────────
    UIView *loopRow = [[UIView alloc] initWithFrame:CGRectMake(pad, y, W-pad*2, 50)];
    loopRow.backgroundColor    = [[UIColor colorWithRed:.0 green:.75 blue:.75 alpha:1]
                                      colorWithAlphaComponent:.18];
    loopRow.layer.cornerRadius = 12;
    loopRow.layer.borderWidth  = 1;
    loopRow.layer.borderColor  = [[UIColor colorWithRed:.0 green:.7 blue:.7 alpha:.6] CGColor];
    [cv addSubview:loopRow];

    UILabel *loopLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, loopRow.bounds.size.width - 70, 50)];
    loopLbl.text      = @"⚡ Auto Spawn (1 ms loop)";
    loopLbl.textColor = [UIColor colorWithRed:.0 green:.3 blue:.3 alpha:1];
    loopLbl.font      = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    loopLbl.numberOfLines = 1;
    [loopRow addSubview:loopLbl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = [UIColor colorWithRed:.0 green:.65 blue:.65 alpha:1];
    sw.on          = _spawnLoopActive;   // reflect current state
    [sw addTarget:self action:@selector(toggleSpawnLoop:)
 forControlEvents:UIControlEventValueChanged];
    sw.center = CGPointMake(loopRow.bounds.size.width - 36,
                            loopRow.bounds.size.height / 2);
    self.spawnLoopSwitch = sw;
    [loopRow addSubview:sw];
    y += 58;

    // update scroll content size
    self.contentScrollView.contentSize = CGSizeMake(W, y + 20);
}

// ── SETTINGS TAB ─────────────────────────────────────────
- (void)loadSettingsTab {
    UIView *cv = self.contentView;
    CGFloat W  = cv.bounds.size.width;
    CGFloat y  = 10;
    CGFloat pad= 12;

    // helper block for labelled rows
    void (^addRow)(NSString *, SEL) = ^(NSString *label, SEL action){
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(pad, y, W-pad*2, 38);
        [btn setTitle:label forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor darkGrayColor] forState:UIControlStateNormal];
        btn.titleLabel.font    = [UIFont systemFontOfSize:14];
        btn.backgroundColor    = [[UIColor whiteColor] colorWithAlphaComponent:.5];
        btn.layer.cornerRadius = 9;
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        UIEdgeInsets ins = UIEdgeInsetsMake(0,12,0,0);
        btn.contentEdgeInsets = ins;
        [btn addTarget:self action:action
      forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:btn];
        y += 44;
    };

    addRow(@"💰  Give Big Money",        @selector(giveBigMoney));
    addRow(@"💸  Give All Players Money", @selector(giveAllPlayersBigMoney));
    addRow(@"🔫  Infinite Ammo",          @selector(giveInfAmmo));
    addRow(@"🛒  Remove Shop Cooldown",   @selector(removeShopCooldown));
    addRow(@"💬  Open Discord",           @selector(openDiscord));

    // custom location toggle
    UIView *locRow = [[UIView alloc] initWithFrame:CGRectMake(pad, y, W-pad*2, 44)];
    locRow.backgroundColor    = [[UIColor whiteColor] colorWithAlphaComponent:.5];
    locRow.layer.cornerRadius = 9;
    [cv addSubview:locRow];

    UILabel *locLbl = [[UILabel alloc] initWithFrame:CGRectMake(12,0,locRow.bounds.size.width-70,44)];
    locLbl.text      = @"📍  Custom Spawn Location";
    locLbl.textColor = [UIColor darkGrayColor];
    locLbl.font      = [UIFont systemFontOfSize:14];
    [locRow addSubview:locLbl];

    UISwitch *locSw = [[UISwitch alloc] init];
    locSw.on     = _useCustomLocation;
    locSw.center = CGPointMake(locRow.bounds.size.width - 36, 22);
    [locSw addTarget:self action:@selector(toggleCustomLocation:)
    forControlEvents:UIControlEventValueChanged];
    [locRow addSubview:locSw];
    y += 50;

    self.contentScrollView.contentSize = CGSizeMake(W, y + 20);
}

// ── picker data source ────────────────────────────────────
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pv {
    return 1;
}
- (NSInteger)pickerView:(UIPickerView *)pv
 numberOfRowsInComponent:(NSInteger)component {
    return (NSInteger)_filteredItems.count;
}
- (NSAttributedString *)pickerView:(UIPickerView *)pv
           attributedTitleForRow:(NSInteger)row
                    forComponent:(NSInteger)component {
    NSString *s = _filteredItems[row];
    return [[NSAttributedString alloc]
        initWithString:s
            attributes:@{NSForegroundColorAttributeName:[UIColor darkGrayColor]}];
}
- (void)pickerView:(UIPickerView *)pv
      didSelectRow:(NSInteger)row
       inComponent:(NSInteger)component {
    _selectedItemIndex = (int)row;
    // if loop is running, it will automatically pick up new selection
}

// ── search ────────────────────────────────────────────────
- (void)searchItemsWithTextField:(UITextField *)tf {
    NSString *q = tf.text.lowercaseString;
    if (q.length == 0) {
        _filteredItems = [_availableItems mutableCopy];
    } else {
        _filteredItems = [NSMutableArray array];
        for (NSString *item in _availableItems)
            if ([item.lowercaseString rangeOfString:q].location != NSNotFound)
                [_filteredItems addObject:item];
    }
    _selectedItemIndex = 0;
    [self.itemPicker reloadAllComponents];
    if (_filteredItems.count > 0)
        [self.itemPicker selectRow:0 inComponent:0 animated:YES];
}

// ── spawn once ────────────────────────────────────────────
- (void)spawnSelectedItem {
    if (_filteredItems.count == 0) return;
    NSString *itemID = _filteredItems[_selectedItemIndex];
    for (int i = 0; i < _spawnQuantity; i++)
        _spawnItem(itemID.UTF8String);
}

// ── AUTO SPAWN LOOP TOGGLE (NEW) ─────────────────────────
- (void)toggleSpawnLoop:(UISwitch *)sender {
    if (sender.isOn) {
        startSpawnLoop();
    } else {
        stopSpawnLoop();
    }
}

// ── quantity stepper ─────────────────────────────────────
- (void)quantityChanged:(UIStepper *)sender {
    _spawnQuantity = (int)sender.value;
    self.quantityLabel.text = [NSString stringWithFormat:@"Qty: %d", _spawnQuantity];
}

// ── settings actions ─────────────────────────────────────
- (void)giveBigMoney          { extern void _giveSelfMoney(void);       _giveSelfMoney(); }
- (void)giveAllPlayersBigMoney{ extern void _giveAllPlayersMoney(void); _giveAllPlayersMoney(); }
- (void)giveInfAmmo           { /* hooked via logos */ }
- (void)removeShopCooldown    { /* hooked via logos */ }
- (void)openDiscord {
    [[UIApplication sharedApplication]
        openURL:[NSURL URLWithString:@"https://discord.gg/xmod"]
        options:@{} completionHandler:nil];
}

- (void)toggleCustomLocation:(UISwitch *)s { _useCustomLocation = s.isOn; }
- (void)applyLocationSettings  {}
- (void)applyPresetLocationAuto{}
- (void)applyPresetLocation:(id)s{}
- (void)resetLocationSettings  { _customSpawnX = _customSpawnY = _customSpawnZ = 0; }
- (void)updateLocationFromFields{}
- (float)floatValueFromFieldTag:(int)t { return 0; }

// ── misc ──────────────────────────────────────────────────
- (void)closeMenu {
    stopSpawnLoop();   // safety: stop loop when menu closes
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)openKeyboard {}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotate { return YES; }

@end

// ── logos hooks (unchanged from original) ─────────────────
%hook NSObject
%end
