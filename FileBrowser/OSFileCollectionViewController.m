//
//  OSFileCollectionViewController.m
//  FileBrowser
//
//  Created by xiaoyuan on 05/08/2014.
//  Copyright © 2014 xiaoyuan. All rights reserved.
//

#import "OSFileCollectionViewController.h"
#import "OSFileCollectionViewCell.h"
#import "OSFileCollectionViewFlowLayout.h"
#import "DirectoryWatcher.h"
#import "OSFileManager.h"
#import "OSFileAttributeItem.h"
#import "FilePreviewViewController.h"
#import <UIScrollView+NoDataExtend.h>
#import "OSFileBottomHUD.h"
#import "NSString+OSFile.h"
#import <MBProgressHUD.h>
#import "NSObject+XYHUD.h"
#import "UIViewController+XYExtensions.h"

#define dispatch_main_safe_async(block)\
    if ([NSThread isMainThread]) {\
    block();\
    } else {\
    dispatch_async(dispatch_get_main_queue(), block);\
    }

NSNotificationName const OSFileCollectionViewControllerOptionFileCompletionNotification = @"OptionFileCompletionNotification";

typedef NS_ENUM(NSInteger, OSFileLoadType) {
    OSFileLoadTypeCurrentDirectory,
    OSFileLoadTypeSubDirectory,
};

static NSString * const reuseIdentifier = @"OSFileCollectionViewCell";
static const CGFloat windowHeight = 49.0;

#ifdef __IPHONE_9_0
@interface OSFileCollectionViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UIViewControllerPreviewingDelegate, NoDataPlaceholderDelegate, OSFileCollectionViewCellDelegate, OSFileBottomHUDDelegate>
#else
@interface OSFileCollectionViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, NoDataPlaceholderDelegate, OSFileCollectionViewCellDelegate, OSFileBottomHUDDelegate>
#endif

{
    DirectoryWatcher *_currentFolderHelper;
    DirectoryWatcher *_documentFolderHelper;
}

@property (nonatomic, strong) OSFileCollectionViewFlowLayout *flowLayout;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPress;
@property (nonatomic, copy) void (^longPressCallBack)(NSIndexPath *indexPath);
@property (nonatomic, strong) NSIndexPath *indexPath;
@property (nonatomic, strong) NSOperationQueue *loadFileQueue;
@property (nonatomic, strong) OSFileManager *fileManager;
@property (nonatomic, strong) MBProgressHUD *hud;
@property (nonatomic, strong) NSArray<NSString *> *directoryArray;
@property (nonatomic, assign) OSFileLoadType fileLoadType;
@property (nonatomic, strong) NSMutableArray<OSFileAttributeItem *> *selectorFiles;
@property (nonatomic, strong) OSFileBottomHUD *bottomHUD;
@property (nonatomic, assign) OSFileCollectionViewControllerMode mode;
@property (nonatomic, weak) UIButton *bottomTipButton;

@end

@implementation OSFileCollectionViewController

////////////////////////////////////////////////////////////////////////
#pragma mark - Initialize
////////////////////////////////////////////////////////////////////////

- (instancetype)initWithRootDirectory:(NSString *)path {
    return [self initWithRootDirectory:path controllerMode:OSFileCollectionViewControllerModeDefault];
}

- (instancetype)initWithRootDirectory:(NSString *)path controllerMode:(OSFileCollectionViewControllerMode)mode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.fileLoadType = OSFileLoadTypeSubDirectory;
        self.mode = mode;
        self.rootDirectory = path;
        [self commonInit];
        
    }
    return self;
}

- (instancetype)initWithDirectoryArray:(NSArray *)directoryArray {
    return [self initWithDirectoryArray:directoryArray controllerMode:OSFileCollectionViewControllerModeDefault];
}

- (instancetype)initWithDirectoryArray:(NSArray *)directoryArray controllerMode:(OSFileCollectionViewControllerMode)mode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.fileLoadType = OSFileLoadTypeCurrentDirectory;
        self.mode = mode;
        self.directoryArray = directoryArray;
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _fileManager = [OSFileManager defaultManager];
    _displayHiddenFiles = NO;
    _loadFileQueue = [NSOperationQueue new];
    __weak typeof(self) weakSelf = self;
    NSString *documentPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    _currentFolderHelper = [DirectoryWatcher watchFolderWithPath:self.rootDirectory directoryDidChange:^(DirectoryWatcher *folderWatcher) {
        [weakSelf reloadFiles];
    }];
    
    if (![self.rootDirectory isEqualToString:documentPath]) {
        _documentFolderHelper = [DirectoryWatcher watchFolderWithPath:documentPath directoryDidChange:^(DirectoryWatcher *folderWatcher) {
            [weakSelf reloadFiles];
        }];
    }
    
    // 如果数组中只有下载文件夹和iTunes文件夹，就不能显示编辑
    BOOL displayEdit = YES;
    if (self.directoryArray && self.directoryArray.count <= 2) {
        NSIndexSet *set = [self.directoryArray indexesOfObjectsPassingTest:^BOOL(NSString * _Nonnull path, NSUInteger idx, BOOL * _Nonnull stop) {
            return [path isEqualToString:[NSString getDownloadLocalFolderPath]] || [path isEqualToString:[NSString getDocumentPath]];
        }];
        if (set.count == self.directoryArray.count) {
            displayEdit = NO;
        }
        if ( self.mode == OSFileCollectionViewControllerModeCopy ||
            self.mode == OSFileCollectionViewControllerModeMove) {
            displayEdit = YES;
        }
    }
    if (displayEdit) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"编辑" style:UIBarButtonItemStylePlain target:self action:@selector(rightBarButtonClick)];
        switch (self.mode) {
            case OSFileCollectionViewControllerModeDefault: {
                self.navigationItem.rightBarButtonItem.title = @"编辑";
                break;
            }
            case OSFileCollectionViewControllerModeEdit: {
                self.navigationItem.rightBarButtonItem.title = @"完成";
                break;
            }
            case OSFileCollectionViewControllerModeCopy:
            case OSFileCollectionViewControllerModeMove: {
                self.navigationItem.rightBarButtonItem.title = @"取消";
                break;
            }
            default:
                break;
        }
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(optionFileCompletion:) name:OSFileCollectionViewControllerOptionFileCompletionNotification object:nil];
    
}

- (void)rightBarButtonClick {
    [self updateMode];
    switch (self.mode) {
        case OSFileCollectionViewControllerModeEdit: {
            [self leaveEditModeAction];
            break;
        }
        case OSFileCollectionViewControllerModeDefault: {
            [self enterEditModeAction];
            break;
        }
        case OSFileCollectionViewControllerModeCopy: {
            [self copyModeAction];
            break;
        }
        case OSFileCollectionViewControllerModeMove: {
            [self moveModeAction];
            break;
        }
        default:
            break;
    }
    
}

- (void)updateMode {
    self.collectionView.allowsMultipleSelection = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    if (self.mode == OSFileCollectionViewControllerModeDefault)  {
        self.mode = OSFileCollectionViewControllerModeEdit;
    }
    else if (self.mode == OSFileCollectionViewControllerModeEdit) {
        self.mode = OSFileCollectionViewControllerModeDefault;
    }
    
    
}

- (void)enterEditModeAction {
    for (OSFileAttributeItem *item in self.files) {
        item.status = OSFileAttributeItemStatusDefault;
    }
    [self.collectionView reloadData];
    self.navigationItem.rightBarButtonItem.title = @"编辑";
    
    [self.bottomHUD hideHudCompletion:^{
        self.navigationItem.rightBarButtonItem.enabled = YES;
        self.bottomHUD = nil;
    }];
}

- (void)leaveEditModeAction {
    self.collectionView.allowsMultipleSelection = YES;
    for (OSFileAttributeItem *item in self.files) {
        item.status = OSFileAttributeItemStatusEdit;
    }
    [self.collectionView reloadData];
    self.navigationItem.rightBarButtonItem.title = @"完成";
    
    [self.bottomHUD showHUDWithFrame:CGRectMake(0, self.view.frame.size.height - windowHeight, self.view.frame.size.width, windowHeight) completion:^{
        self.navigationItem.rightBarButtonItem.enabled = YES;
    }];
}

- (void)copyModeAction {
    [self backButtonClick];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}

- (void)moveModeAction {
    [self backButtonClick];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}


- (OSFileBottomHUD *)bottomHUD {
    if (!_bottomHUD) {
        _bottomHUD = [[OSFileBottomHUD alloc] initWithItems:@[
                                                              [[OSFileBottomHUDItem alloc] initWithTitle:@"复制" image:nil],
                                                              [[OSFileBottomHUDItem alloc] initWithTitle:@"移动" image:nil],
                                                              [[OSFileBottomHUDItem alloc] initWithTitle:@"删除" image:nil],
                                                              ] toView:self.view];
        _bottomHUD.delegate = self;
    }
    return _bottomHUD;
}


- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    [self setupViews];
    __weak typeof(self) weakSelf = self;
    switch (self.fileLoadType) {
        case OSFileLoadTypeCurrentDirectory: {
            [self loadFileWithDirectoryArray:self.directoryArray completion:^(NSArray *fileItems) {
                weakSelf.files = fileItems.copy;
                [weakSelf.collectionView reloadData];
                [weakSelf showBottomTip];
            }];
            break;
        }
        case OSFileLoadTypeSubDirectory: {
            [self loadFileWithDirectoryPath:self.rootDirectory completion:^(NSArray *fileItems) {
                weakSelf.files = fileItems.copy;
                [weakSelf.collectionView reloadData];
                [weakSelf showBottomTip];
            }];
            break;
        }
        default:
            break;
    }
    
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self check3DTouch];
    
    if ((self.mode == OSFileCollectionViewControllerModeCopy ||
         self.mode == OSFileCollectionViewControllerModeMove) &&
        self.rootDirectory.length) {
        [self bottomTipButton].hidden = NO;
    }
    else {
        [self bottomTipButton].hidden = YES;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.bottomHUD hideHudCompletion:^{
        self.navigationItem.rightBarButtonItem.enabled = YES;
        self.bottomHUD = nil;
    }];
    if (self.mode == OSFileCollectionViewControllerModeEdit) {
        [self rightBarButtonClick];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self bottomTipButton].hidden = YES;
}

- (void)dealloc {
    self.bottomHUD = nil;
    [_bottomTipButton removeFromSuperview];
    _bottomTipButton = nil;
    self.directoryArray = nil;
    [_currentFolderHelper invalidate];
    [_documentFolderHelper invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupViews {
    self.navigationItem.title = @"文件管理";
    if (self.rootDirectory.length) {
        self.navigationItem.title = [self.rootDirectory lastPathComponent];
        if ([self.rootDirectory isEqualToString:[NSString getDocumentPath]]) {
            self.navigationItem.title = @"iTunes文件";
        }
        else if ([self.rootDirectory isEqualToString:[NSString getDownloadLocalFolderPath]]) {
            self.navigationItem.title = @"下载";
        }
    }
    self.view.backgroundColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    
    [self.view addSubview:self.collectionView];
    [self makeCollectionViewConstr];
    [self setupNodataView];
}

- (void)setupNodataView {
    __weak typeof(self) weakSelf = self;
    
    self.collectionView.noDataPlaceholderDelegate = self;
    if ([self isDownloadBrowser]) {
        self.collectionView.customNoDataView = ^UIView * _Nonnull{
            if (weakSelf.collectionView.xy_loading) {
                UIActivityIndicatorView *activityView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
                [activityView startAnimating];
                return activityView;
            }
            else {
                return nil;
            }
            
        };
        
        
        self.collectionView.noDataDetailTextLabelBlock = ^(UILabel * _Nonnull detailTextLabel) {
            NSAttributedString *string = [weakSelf noDataDetailLabelAttributedString];
            if (!string.length) {
                return;
            }
            detailTextLabel.backgroundColor = [UIColor clearColor];
            detailTextLabel.font = [UIFont systemFontOfSize:17.0];
            detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            detailTextLabel.textAlignment = NSTextAlignmentCenter;
            detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
            detailTextLabel.numberOfLines = 0;
            detailTextLabel.attributedText = string;
        };
        self.collectionView.noDataImageViewBlock = ^(UIImageView * _Nonnull imageView) {
            imageView.backgroundColor = [UIColor clearColor];
            imageView.contentMode = UIViewContentModeScaleAspectFit;
            imageView.userInteractionEnabled = NO;
            imageView.image = [weakSelf noDataImageViewImage];
            
        };
        
        self.collectionView.noDataReloadButtonBlock = ^(UIButton * _Nonnull reloadButton) {
            reloadButton.backgroundColor = [UIColor clearColor];
            reloadButton.layer.borderWidth = 0.5;
            reloadButton.layer.borderColor = [UIColor colorWithRed:49/255.0 green:194/255.0 blue:124/255.0 alpha:1.0].CGColor;
            reloadButton.layer.cornerRadius = 2.0;
            [reloadButton.layer setMasksToBounds:YES];
            [reloadButton setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];
            [reloadButton setAttributedTitle:[weakSelf noDataReloadButtonAttributedStringWithState:UIControlStateNormal] forState:UIControlStateNormal];
        };
        
        self.collectionView.noDataButtonEdgeInsets = UIEdgeInsetsMake(20, 100, 11, 100);
    }
    self.collectionView.noDataTextLabelBlock = ^(UILabel * _Nonnull textLabel) {
        NSAttributedString *string = [weakSelf noDataTextLabelAttributedString];
        if (!string.length) {
            return;
        }
        textLabel.backgroundColor = [UIColor clearColor];
        textLabel.font = [UIFont systemFontOfSize:27.0];
        textLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        textLabel.textAlignment = NSTextAlignmentCenter;
        textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        textLabel.numberOfLines = 0;
        textLabel.attributedText = string;
    };
    
    self.collectionView.noDataTextEdgeInsets = UIEdgeInsetsMake(20, 0, 20, 0);
    
    
}

- (void)loadFileWithDirectoryArray:(NSArray<NSString *> *)directoryArray completion:(void (^)(NSArray *fileItems))completion {
    [_loadFileQueue cancelAllOperations];
    [_loadFileQueue addOperationWithBlock:^{
        NSMutableArray *array = @[].mutableCopy;
        [directoryArray enumerateObjectsUsingBlock:^(NSString * _Nonnull fullPath, NSUInteger idx, BOOL * _Nonnull stop) {
            OSFileAttributeItem *model = [[OSFileAttributeItem alloc] initWithPath:fullPath];
            if (model) {
                if (self.mode == OSFileCollectionViewControllerModeEdit) {
                    model.status = OSFileAttributeItemStatusEdit;
                }
                NSError *error = nil;
                NSArray *subFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fullPath error:&error];
                if (!error) {
                    if (!_displayHiddenFiles) {
                        subFiles = [self removeHiddenFilesFromFiles:subFiles];
                    }
                    model.subFileCount = subFiles.count;
                }
                
                [array addObject:model];
            }
        }];
        
        
        if (!_displayHiddenFiles) {
            array = [[self removeHiddenFilesFromFiles:array] mutableCopy];
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(array);
            });
        }
        
    }];
    
    
}

- (void)loadFileWithDirectoryPath:(NSString *)directoryPath completion:(void (^)(NSArray *fileItems))completion {
    [_loadFileQueue cancelAllOperations];
    [_loadFileQueue addOperationWithBlock:^{
        
        NSError *error = nil;
        NSArray *tempFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directoryPath error:&error];
        if (error) {
            NSLog(@"Error: %@", error);
        }
        NSArray *files = [self sortedFiles:tempFiles];
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:files.count];
        [files enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            NSString *fullPath = [directoryPath stringByAppendingPathComponent:obj];
            OSFileAttributeItem *model = [[OSFileAttributeItem alloc] initWithPath:fullPath];
            if (model) {
                if (self.mode == OSFileCollectionViewControllerModeEdit) {
                    model.status = OSFileAttributeItemStatusEdit;
                }
                NSError *error = nil;
                NSArray *subFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fullPath error:&error];
                if (!error) {
                    if (!_displayHiddenFiles) {
                        subFiles = [self removeHiddenFilesFromFiles:subFiles];
                    }
                    model.subFileCount = subFiles.count;
                }
                
                [array addObject:model];
            }
            
        }];
        
        if (!_displayHiddenFiles) {
            array = [[self removeHiddenFilesFromFiles:array] mutableCopy];
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(array);
            });
        }
    }];
}

- (void)setDisplayHiddenFiles:(BOOL)displayHiddenFiles {
    if (_displayHiddenFiles == displayHiddenFiles) {
        return;
    }
    _displayHiddenFiles = displayHiddenFiles;
    __weak typeof(self) weakSelf = self;
    switch (self.fileLoadType) {
        case OSFileLoadTypeCurrentDirectory: {
            [self loadFileWithDirectoryArray:self.directoryArray completion:^(NSArray *fileItems) {
                weakSelf.files = fileItems.copy;
                [weakSelf.collectionView reloadData];
            }];
            break;
        }
        case OSFileLoadTypeSubDirectory: {
            [self loadFileWithDirectoryPath:self.rootDirectory completion:^(NSArray *fileItems) {
                weakSelf.files = fileItems.copy;
                [weakSelf.collectionView reloadData];
            }];
            break;
        }
        default:
            break;
    }
    
}

- (NSArray *)removeHiddenFilesFromFiles:(NSArray *)files {
    @synchronized (self) {
        NSMutableArray *tempFiles = [files mutableCopy];
        NSIndexSet *indexSet = [tempFiles indexesOfObjectsPassingTest:^BOOL(OSFileAttributeItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([obj isKindOfClass:[OSFileAttributeItem class]]) {
                return [obj.fullPath.lastPathComponent hasPrefix:@"."];
            } else if ([obj isKindOfClass:[NSString class]]) {
                NSString *path = (NSString *)obj;
                return [path.lastPathComponent hasPrefix:@"."];
            }
            return NO;
        }];
        [tempFiles removeObjectsAtIndexes:indexSet];
        return tempFiles;
    }
    
}


- (void)reloadFiles {
    __weak typeof(self) weakSelf = self;
    switch (self.fileLoadType) {
        case OSFileLoadTypeCurrentDirectory: {
            [self loadFileWithDirectoryArray:self.directoryArray completion:^(NSArray *fileItems) {
                weakSelf.files = fileItems.copy;
                [weakSelf.collectionView reloadData];
            }];
            break;
        }
        case OSFileLoadTypeSubDirectory: {
            [self loadFileWithDirectoryPath:self.rootDirectory completion:^(NSArray *fileItems) {
                weakSelf.files = fileItems.copy;
                [weakSelf.collectionView reloadData];
            }];
            break;
        }
        default:
            break;
    }
    
}

- (void)check3DTouch {
    /// 检测是否有3d touch 功能
    if ([self respondsToSelector:@selector(traitCollection)]) {
        if ([self.traitCollection respondsToSelector:@selector(forceTouchCapability)]) {
            if (self.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable) {
                // 支持3D Touch
                if ([self respondsToSelector:@selector(registerForPreviewingWithDelegate:sourceView:)]) {
                    [self registerForPreviewingWithDelegate:self sourceView:self.view];
                    self.longPress.enabled = NO;
                }
            } else {
                // 不支持3D Touch
                self.longPress.enabled = YES;
            }
        }
    }
}
////////////////////////////////////////////////////////////////////////
#pragma mark - 3D Touch Delegate
////////////////////////////////////////////////////////////////////////

#ifdef __IPHONE_9_0
- (UIViewController *)previewingContext:(id<UIViewControllerPreviewing>)previewingContext viewControllerForLocation:(CGPoint)location {
    // 需要将location在self.view上的坐标转换到tableView上，才能从tableView上获取到当前indexPath
    CGPoint targetLocation = [self.view convertPoint:location toView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:targetLocation];
    _indexPath = indexPath;
    UIViewController *vc = [self previewControllerByIndexPath:indexPath];
    // 预览区域大小(可不设置)
    vc.preferredContentSize = CGSizeMake(0, 320);
    return vc;
}



- (void)previewingContext:(id<UIViewControllerPreviewing>)previewingContext commitViewController:(UIViewController *)viewControllerToCommit {
    [self showViewController:viewControllerToCommit sender:self];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    
    [self check3DTouch];
}

#endif



////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1;
}


- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.files.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    OSFileCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier forIndexPath:indexPath];
    cell.fileModel = self.files[indexPath.row];
    cell.delegate = self;
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    
    if (self.mode == OSFileCollectionViewControllerModeEdit) {
        OSFileAttributeItem *item = self.files[indexPath.row];
        item.status = OSFileAttributeItemStatusChecked;
        if (![self.selectorFiles containsObject:item]) {
            [self.selectorFiles addObject:item];
        }
        [collectionView reloadItemsAtIndexPaths:@[indexPath]];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [collectionView selectItemAtIndexPath:indexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
        });
    } else {
        self.indexPath = indexPath;
        UIViewController *vc = [self previewControllerByIndexPath:indexPath];
        [self jumpToDetailControllerToViewController:vc atIndexPath:indexPath];
    }
}

- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == OSFileCollectionViewControllerModeEdit) {
        OSFileAttributeItem *item = self.files[indexPath.row];
        item.status = OSFileAttributeItemStatusEdit;
        [self.selectorFiles removeObject:item];
        [collectionView reloadItemsAtIndexPaths:@[indexPath]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [collectionView deselectItemAtIndexPath:indexPath animated:YES];
        });
    }
}


////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////

- (void)jumpToDetailControllerToViewController:(UIViewController *)viewController atIndexPath:(NSIndexPath *)indexPath {
    NSString *newPath = self.files[indexPath.row].fullPath;
    BOOL isDirectory;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:newPath isDirectory:&isDirectory];
    NSURL *url = [NSURL fileURLWithPath:newPath];
    if (fileExists) {
        if (isDirectory) {
            OSFileCollectionViewController *vc = (OSFileCollectionViewController *)viewController;
            [self.navigationController showViewController:vc sender:self];
            
        } else if (![QLPreviewController canPreviewItem:url]) {
            FilePreviewViewController *preview = (FilePreviewViewController *)viewController;
            preview.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(backButtonClick)];
            UINavigationController *detailNavController = [[UINavigationController alloc] initWithRootViewController:preview];
            
            [self.navigationController showDetailViewController:detailNavController sender:self];
        } else {
            
            QLPreviewController *preview = (QLPreviewController *)viewController;
            preview.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(backButtonClick)];
            UINavigationController *detailNavController = [[UINavigationController alloc] initWithRootViewController:preview];
            [self.navigationController showDetailViewController:detailNavController sender:self];
        }
    }
}

- (void)backButtonClick {
    UIViewController *rootViewController = (UINavigationController *)[UIApplication sharedApplication].delegate.window.rootViewController;
    if ([rootViewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nac = (UINavigationController *)rootViewController;
        if (self.presentedViewController || nac.topViewController.presentedViewController) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            [self.navigationController popViewControllerAnimated:YES];
        }
    }
    else if ([rootViewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabc = (UITabBarController *)rootViewController;
        UINavigationController *nac = tabc.selectedViewController;
        if ([nac isKindOfClass:[UINavigationController class]]) {
            if (self.presentedViewController || nac.presentedViewController) {
                [self dismissViewControllerAnimated:YES completion:nil];
            } else {
                [self.navigationController popViewControllerAnimated:YES];
            }
        }
        
    }
    
}


- (UIViewController *)previewControllerByIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || !self.files.count) {
        return nil;
    }
    NSString *newPath = self.files[indexPath.row].fullPath;
    NSURL *url = [NSURL fileURLWithPath:newPath];
    BOOL isDirectory;
    BOOL fileExists = [[NSFileManager defaultManager ] fileExistsAtPath:newPath isDirectory:&isDirectory];
    UIViewController *vc = nil;
    if (fileExists) {
        if (isDirectory) {
            /// 如果当前界面是OSFileCollectionViewControllerModeCopy，那么下一个界面也要是同样的模式
            OSFileCollectionViewControllerMode mode = OSFileCollectionViewControllerModeDefault;
            if (self.mode == OSFileCollectionViewControllerModeCopy ||
                self.mode == OSFileCollectionViewControllerModeMove) {
                mode = self.mode;
            }
            vc = [[OSFileCollectionViewController alloc] initWithRootDirectory:newPath controllerMode:mode];
            if (self.mode == OSFileCollectionViewControllerModeCopy ||
                self.mode == OSFileCollectionViewControllerModeMove) {
                OSFileCollectionViewController *viewController = (OSFileCollectionViewController *)vc;
                viewController.selectorFiles = self.selectorFiles.mutableCopy;
            }
            
        } else if (![QLPreviewController canPreviewItem:url]) {
            vc = [[FilePreviewViewController alloc] initWithPath:newPath];
        } else {
            QLPreviewController *preview= [[QLPreviewController alloc] init];
            preview.dataSource = self;
            vc = preview;
        }
    }
    return vc;
}

////////////////////////////////////////////////////////////////////////
#pragma mark - QLPreviewControllerDataSource
////////////////////////////////////////////////////////////////////////

- (BOOL)previewController:(QLPreviewController *)controller shouldOpenURL:(NSURL *)url forPreviewItem:(id <QLPreviewItem>)item {
    
    return YES;
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return 1;
}

- (id <QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger) index {
    NSString *newPath = self.files[self.indexPath.row].fullPath;
    
    return [NSURL fileURLWithPath:newPath];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - Sorted files
////////////////////////////////////////////////////////////////////////
- (NSArray *)sortedFiles:(NSArray *)files {
    return [files sortedArrayWithOptions:NSSortConcurrent usingComparator:^NSComparisonResult(NSString* file1, NSString* file2) {
        NSString *newPath1 = [self.rootDirectory stringByAppendingPathComponent:file1];
        NSString *newPath2 = [self.rootDirectory stringByAppendingPathComponent:file2];
        
        BOOL isDirectory1, isDirectory2;
        [[NSFileManager defaultManager ] fileExistsAtPath:newPath1 isDirectory:&isDirectory1];
        [[NSFileManager defaultManager ] fileExistsAtPath:newPath2 isDirectory:&isDirectory2];
        
        if (isDirectory1 && !isDirectory2) {
            return NSOrderedAscending;
        }
        
        return  NSOrderedDescending;
    }];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - Actions
////////////////////////////////////////////////////////////////////////

- (UILongPressGestureRecognizer *)longPress {
    
    if (!_longPress) {
        _longPress = [[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(showPeek:)];
        [self.view addGestureRecognizer:_longPress];
    }
    return _longPress;
}

- (void)showPeek:(UILongPressGestureRecognizer *)longPress {
    if (longPress.state == UIGestureRecognizerStateBegan) {
        CGPoint point = [longPress locationInView:self.collectionView];
        NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
        
        if (self.longPressCallBack) {
            self.longPressCallBack(indexPath);
        }
        
        self.longPress.enabled = NO;
        UIViewController *vc = [self previewControllerByIndexPath:indexPath];
        [self jumpToDetailControllerToViewController:vc atIndexPath:indexPath];
    }
}



////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////

- (void)makeCollectionViewConstr {
    
    NSDictionary *views = NSDictionaryOfVariableBindings(_collectionView);
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[_collectionView]|" options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[_collectionView]|" options:0 metrics:nil views:views]];
}


- (OSFileCollectionViewFlowLayout *)flowLayout {
    
    if (_flowLayout == nil) {
        
        OSFileCollectionViewFlowLayout *layout = [OSFileCollectionViewFlowLayout new];
        _flowLayout = layout;
        layout.itemSpacing = 20.0;
        layout.lineSpacing = 20.0;
        layout.lineSize = 30.0;
        layout.lineItemCount = 3;
        layout.lineMultiplier = 1.19;
        layout.scrollDirection = UICollectionViewScrollDirectionVertical;
        layout.sectionsStartOnNewLine = NO;
        
    }
    return _flowLayout;
}

- (UICollectionView *)collectionView {
    if (_collectionView == nil) {
        
        UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:self.flowLayout];
        collectionView.dataSource = self;
        collectionView.delegate = self;
        collectionView.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        [collectionView registerClass:[OSFileCollectionViewCell class] forCellWithReuseIdentifier:reuseIdentifier];
        _collectionView = collectionView;
        _collectionView.translatesAutoresizingMaskIntoConstraints = NO;
        _collectionView.contentInset = UIEdgeInsetsMake(20, 20, 0, 20);
    }
    return _collectionView;
}

- (MBProgressHUD *)hud {
    if (!_hud) {
        _hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].delegate.window animated:YES];
        [_hud.button setTitle:NSLocalizedString(@"Cancel", @"HUD cancel button title") forState:UIControlStateNormal];
        _hud.mode = MBProgressHUDModeDeterminate;
        [_hud.button addTarget:self action:@selector(cancelFileOperation:) forControlEvents:UIControlEventTouchUpInside];
    }
    return _hud;
}

- (UIButton *)bottomTipButton {
    if (!_bottomTipButton) {
        UIButton *bottomTipButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _bottomTipButton = bottomTipButton;
        [self.view addSubview:bottomTipButton];
        bottomTipButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|[bottomTipButton]|" options:kNilOptions metrics:nil views:@{@"bottomTipButton": bottomTipButton}]];
        [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[bottomTipButton(==49.0)]|" options:kNilOptions metrics:nil views:@{@"bottomTipButton": bottomTipButton}]];
        [bottomTipButton setBackgroundColor:[UIColor blueColor]];
        [bottomTipButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        bottomTipButton.titleLabel.numberOfLines = 3;
        bottomTipButton.titleLabel.adjustsFontSizeToFitWidth = YES;
        bottomTipButton.titleLabel.minimumScaleFactor = 0.5;
        bottomTipButton.titleLabel.font = [UIFont systemFontOfSize:12.0];
        [_bottomTipButton addTarget:self action:@selector(chooseCompletion) forControlEvents:UIControlEventTouchUpInside];
    }
    
    return _bottomTipButton;
}

- (NSMutableArray<OSFileAttributeItem *> *)selectorFiles {
    if (!_selectorFiles) {
        _selectorFiles = @[].mutableCopy;
    }
    return _selectorFiles;
}

- (void)showBottomTip {
    if ((self.mode != OSFileCollectionViewControllerModeCopy &&
         self.mode != OSFileCollectionViewControllerModeMove) ||
        !self.rootDirectory.length) {
        _bottomTipButton.hidden = YES;
        return;
    }
    
    _bottomTipButton.hidden = NO;
    NSString *string = @"复制";
    if (self.mode == OSFileCollectionViewControllerModeMove) {
        string = @"移动";
    }
    [_bottomTipButton setTitle:[NSString stringWithFormat:@"【%@到(%@)目录】", string, self.rootDirectory.lastPathComponent] forState:UIControlStateNormal];
    /// 检测已选择的文件是否在当前文件中，如果在就提示用户
    NSMutableArray *containFileArray = @[].mutableCopy;
    if (self.files) {
        [self.selectorFiles enumerateObjectsUsingBlock:^(OSFileAttributeItem * _Nonnull seleFile, NSUInteger idx, BOOL * _Nonnull stop) {
            NSUInteger foundIdx = [self.files indexOfObjectPassingTest:^BOOL(OSFileAttributeItem * _Nonnull file, NSUInteger idx, BOOL * _Nonnull stop) {
                BOOL res = NO;
                if ([seleFile.path isEqualToString:file.path]) {
                    res = YES;
                    *stop = YES;
                }
                return res;
            }];
            if (foundIdx != NSNotFound) {
                [containFileArray addObject:seleFile.displayName];
            }
        }];
        
        if (containFileArray.count) {
            string = [containFileArray componentsJoinedByString:@","];
            string = [NSString stringWithFormat:@"请确认，已存在的文件会被替换:(%@)", string];
            [_bottomTipButton setTitle:string forState:UIControlStateNormal];
        }
    }
    
    [self.view bringSubviewToFront:_bottomTipButton];
}

/// 将选择的文件拷贝到目标目录中
- (void)chooseCompletion {
    __weak typeof(self) weakSelf = self;
    [self copyFiles:self.selectorFiles toRootDirectory:self.rootDirectory completionHandler:^(NSError *error) {
        if (!error) {
            [weakSelf.selectorFiles removeAllObjects];
            [[NSNotificationCenter defaultCenter] postNotificationName:OSFileCollectionViewControllerOptionFileCompletionNotification object:nil userInfo:@{@"OSFileCollectionViewControllerMode": @(weakSelf.mode)}];
            [weakSelf backButtonClick];
        }
    }];
    
}

////////////////////////////////////////////////////////////////////////
#pragma mark - OSFileBottomHUDDelegate
////////////////////////////////////////////////////////////////////////

- (void)fileBottomHUD:(OSFileBottomHUD *)hud didClickItem:(OSFileBottomHUDItem *)item {
    switch (item.buttonIdx) {
        case 0: { // 复制
            if (!self.selectorFiles.count) {
                [self showInfo:@"请选择需要复制的文件"];
            }
            else {
                [self chooseDesDirectoryToCopy];
            }
            
            break;
        }
        case 1: { // 移动
            if (!self.selectorFiles.count) {
                [self showInfo:@"请选择需要移动的文件"];
            }
            else {
                [self chooseDesDirectoryToMove];
            }
            break;
        }
        case 2: { // 删除
            if (!self.selectorFiles.count) {
                [self showInfo:@"请选择需要删除的文件"];
            }
            else {
                [self deleteSelectFiles];
            }
            break;
        }
        default:
            break;
    }
}

/// 选择文件最终复制的目标目录
- (void)chooseDesDirectoryToCopy {
    OSFileCollectionViewController *vc = [[OSFileCollectionViewController alloc] initWithDirectoryArray:@[
                                                                                                          [NSString getDownloadLocalFolderPath],
                                                                                                          [NSString getDocumentPath]] controllerMode:OSFileCollectionViewControllerModeCopy];
    UINavigationController *nac = [[[self.navigationController class] alloc] initWithRootViewController:vc];
    vc.selectorFiles = self.selectorFiles.mutableCopy;
    [self showDetailViewController:nac sender:self];
}

- (void)chooseDesDirectoryToMove {
    OSFileCollectionViewController *vc = [[OSFileCollectionViewController alloc] initWithDirectoryArray:@[
                                                                                                          [NSString getDownloadLocalFolderPath],
                                                                                                          [NSString getDocumentPath]] controllerMode:OSFileCollectionViewControllerModeMove];
    UINavigationController *nac = [[[self.navigationController class] alloc] initWithRootViewController:vc];
    vc.selectorFiles = self.selectorFiles.mutableCopy;
    [self showDetailViewController:nac sender:self];
}


- (void)deleteSelectFiles {
    if (!self.selectorFiles.count) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确定删除吗" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        for (OSFileAttributeItem *item in self.selectorFiles ) {
            NSString *currentPath = item.path;
            NSError *error = nil;
            BOOL isSuccess = [[NSFileManager defaultManager] removeItemAtPath:currentPath error:&error];
            if (!isSuccess && error) {
                [[[UIAlertView alloc] initWithTitle:@"Remove error" message:nil delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil, nil] show];
            }
        }
        
        [self reloadFiles];
        
    }]];
    [[UIViewController xy_topViewController] presentViewController:alert animated:true completion:nil];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - OSFileCollectionViewCellDelegate
////////////////////////////////////////////////////////////////////////

- (void)fileCollectionViewCell:(OSFileCollectionViewCell *)cell fileAttributeChange:(OSFileAttributeItem *)fileModel {
    NSUInteger foudIdx = [self.files indexOfObject:fileModel];
    if (foudIdx != NSNotFound) {
        OSFileAttributeItem *item = [OSFileAttributeItem fileWithPath:fileModel.fullPath];
        NSMutableArray *files = self.files.mutableCopy;
        [files replaceObjectAtIndex:foudIdx withObject:item];
        self.files = files;
        [self.collectionView reloadData];
    }
}

- (void)fileCollectionViewCell:(OSFileCollectionViewCell *)cell needCopyFile:(OSFileAttributeItem *)fileModel {
    [self.selectorFiles removeAllObjects];
    [self.selectorFiles addObject:fileModel];
    [self chooseDesDirectoryToCopy];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - Notification
////////////////////////////////////////////////////////////////////////
/// 文件操作文件，比如复制、移动文件完成
- (void)optionFileCompletion:(NSNotification *)notification {
    [self.selectorFiles removeAllObjects];
    self.mode = OSFileCollectionViewControllerModeDefault;
    [self reloadFiles];
}

////////////////////////////////////////////////////////////////////////
#pragma mark - 文件操作
////////////////////////////////////////////////////////////////////////

/// copy 文件
- (void)copyFiles:(NSArray<OSFileAttributeItem *> *)fileItems
  toRootDirectory:(NSString *)rootPath
completionHandler:(void (^)(NSError *error))completion {
    if (!fileItems.count) {
        return;
    }
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        [fileItems enumerateObjectsUsingBlock:^(OSFileAttributeItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            
            NSString *desPath = [rootPath stringByAppendingPathComponent:[obj.fullPath lastPathComponent]];
            if ([desPath isEqualToString:obj.fullPath]) {
                NSLog(@"路径相同");
                dispatch_main_safe_async(^{
                    self.hud.labelText = @"路径相同";
                    if (completion) {
                        completion([NSError errorWithDomain:NSURLErrorDomain code:10000 userInfo:@{@"error": @"不能拷贝到自己的目录"}]);
                    }
                });
            }
            else if ([[NSFileManager defaultManager] fileExistsAtPath:desPath]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.hud.labelText = @"存在相同文件，正在移除原文件";
                });
                NSError *removeError = nil;
                [[NSFileManager defaultManager] removeItemAtPath:desPath error:&removeError];
                if (removeError) {
                    NSLog(@"Error: %@", removeError.localizedDescription);
                }
            }
        }];
    }];
    
    NSMutableArray *hudDetailTextArray = @[].mutableCopy;
    
    void (^hudDetailTextCallBack)(NSString *detailText, NSInteger index) = ^(NSString *detailText, NSInteger index){
        @synchronized (hudDetailTextArray) {
            [hudDetailTextArray replaceObjectAtIndex:index withObject:detailText];
        }
    };
    
    
    operation.completionBlock = ^{
        /// 当completionCopyNum为0 时 全部拷贝完成
        __block NSInteger completionCopyNum = fileItems.count;
        [fileItems enumerateObjectsUsingBlock:^(OSFileAttributeItem *  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [hudDetailTextArray addObject:@(idx).stringValue];
            NSString *desPath = [rootPath stringByAppendingPathComponent:[obj.fullPath lastPathComponent]];
            NSURL *desURL = [NSURL fileURLWithPath:desPath];
            
            void (^ progressBlock)(NSProgress *progress) = ^ (NSProgress *progress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *completionSize = [NSString transformedFileSizeValue:@(progress.completedUnitCount)];
                    NSString *totalSize = [NSString transformedFileSizeValue:@(progress.totalUnitCount)];
                    NSString *prcent = [NSString percentageString:progress.fractionCompleted];
                    NSString *detailText = [NSString stringWithFormat:@"%@  %@/%@", prcent, completionSize, totalSize];
                    hudDetailTextCallBack(detailText, idx);
                });
            };
            
            void (^ completionHandler)(id<OSFileOperation> fileOperation, NSError *error) = ^(id<OSFileOperation> fileOperation, NSError *error) {
                completionCopyNum--;
                dispatch_main_safe_async(^{
                    if (completionCopyNum == 0 && completion) {
                        completion(error);
                    }
                });
            };
            NSURL *orgURL = [NSURL fileURLWithPath:obj.fullPath];
            if (self.mode == OSFileCollectionViewControllerModeCopy) {
                [_fileManager copyItemAtURL:orgURL
                                      toURL:desURL
                                   progress:progressBlock
                          completionHandler:completionHandler];
            }
            else {
                [_fileManager moveItemAtURL:orgURL
                                      toURL:desURL
                                   progress:progressBlock
                          completionHandler:completionHandler];
            }
            
        }];
    };
    
    
    
    [_loadFileQueue addOperation:operation];
    
    __weak typeof(self) weakSelf = self;
    
    _fileManager.totalProgressBlock = ^(NSProgress *progress) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.hud.labelText = [NSString stringWithFormat:@"total:%@  %lld/%lld", [NSString percentageString:progress.fractionCompleted], progress.completedUnitCount, progress.totalUnitCount];
        strongSelf.hud.progress = progress.fractionCompleted;
        @synchronized (hudDetailTextArray) {
            NSString *detailStr = [hudDetailTextArray componentsJoinedByString:@",\n"];
            strongSelf.hud.detailsLabel.text = detailStr;
            
        }
        if (progress.fractionCompleted >= 1.0 || progress.completedUnitCount >= progress.totalUnitCount) {
            strongSelf.hud.labelText = @"完成";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [MBProgressHUD hideAllHUDsForView:[UIApplication sharedApplication].delegate.window animated:YES];
                strongSelf.hud = nil;
            });
        }
    };
    
}


- (void)cancelFileOperation:(id)sender {
    [_fileManager cancelAllOperation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [MBProgressHUD hideAllHUDsForView:[UIApplication sharedApplication].delegate.window animated:YES];
        self.hud = nil;
    });
}


////////////////////////////////////////////////////////////////////////
#pragma mark - NoDataPlaceholderDelegate
////////////////////////////////////////////////////////////////////////

- (BOOL)noDataPlaceholderShouldAllowScroll:(UIScrollView *)scrollView {
    return YES;
}

- (void)noDataPlaceholder:(UIScrollView *)scrollView didTapOnContentView:(UITapGestureRecognizer *)tap {
    [self noDataPlaceholder:scrollView didTapOnContentView:tap];
}


- (CGFloat)contentOffsetYForNoDataPlaceholder:(UIScrollView *)scrollView {
    if ([UIDevice currentDevice].orientation == UIDeviceOrientationPortrait) {
        return 120.0;
    }
    return 80.0;
}

- (void)noDataPlaceholderWillAppear:(UIScrollView *)scrollView {
    
}

- (void)noDataPlaceholderDidDisappear:(UIScrollView *)scrollView {
    
}

- (BOOL)noDataPlaceholderShouldFadeInOnDisplay:(UIScrollView *)scrollView {
    return YES;
}


- (NSAttributedString *)noDataDetailLabelAttributedString {
    return nil;
}

- (UIImage *)noDataImageViewImage {
    
    return [UIImage imageNamed:@"file_noData"];
}


- (NSAttributedString *)noDataReloadButtonAttributedStringWithState:(UIControlState)state {
    return [self attributedStringWithText:@"查看下载页" color:[UIColor colorWithRed:49/255.0 green:194/255.0 blue:124/255.0 alpha:1.0] fontSize:15.0];
}

- (void)noDataPlaceholder:(UIScrollView *)scrollView didClickReloadButton:(UIButton *)button {
    self.tabBarController.selectedIndex = 1;
    self.navigationController.viewControllers = @[self.navigationController.viewControllers.firstObject];
}


- (NSAttributedString *)noDataTextLabelAttributedString {
    NSString *string = nil;
    if ([self isDownloadBrowser]) {
        string = @"下载完成的文件在这显示";
    }
    else {
        string = @"没有文件";
    }
    return [self attributedStringWithText:string color:[UIColor grayColor] fontSize:16];;
}

- (NSAttributedString *)attributedStringWithText:(NSString *)string color:(UIColor *)color fontSize:(CGFloat)fontSize {
    NSString *text = string;
    UIFont *font = [UIFont systemFontOfSize:fontSize];
    UIColor *textColor = color;
    
    NSMutableDictionary *attributeDict = [NSMutableDictionary new];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByWordWrapping;
    style.alignment = NSTextAlignmentCenter;
    style.lineSpacing = 4.0;
    [attributeDict setObject:font forKey:NSFontAttributeName];
    [attributeDict setObject:textColor forKey:NSForegroundColorAttributeName];
    [attributeDict setObject:style forKey:NSParagraphStyleAttributeName];
    
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:text attributes:attributeDict];
    
    return attributedString;
    
}

////////////////////////////////////////////////////////////////////////
#pragma mark - Others
////////////////////////////////////////////////////////////////////////

- (BOOL)isDownloadBrowser {
    return [self.rootDirectory isEqualToString:[NSString getDownloadLocalFolderPath]];
}


@end
