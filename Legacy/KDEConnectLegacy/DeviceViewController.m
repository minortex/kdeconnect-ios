//
//  DeviceViewController.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "DeviceViewController.h"
#import "KDECDeviceInfo.h"
#import "KDECService.h"

@interface DeviceViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) KDECDeviceInfo *device;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *activityLabel;
@end

@implementation DeviceViewController

- (instancetype)initWithDevice:(KDECDeviceInfo *)device
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _device = device;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.device.name;
    self.view.backgroundColor = [UIColor whiteColor];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [self.view addSubview:stack];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:self.statusLabel];
    self.activityLabel = [[UILabel alloc] init];
    self.activityLabel.textAlignment = NSTextAlignmentCenter;
    self.activityLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.activityLabel.textColor = [UIColor darkGrayColor];
    [stack addArrangedSubview:self.activityLabel];
    [stack addArrangedSubview:[self buttonWithTitle:@"Send file"
                                             action:@selector(sendFile:)]];
    [stack addArrangedSubview:[self buttonWithTitle:@"Send clipboard"
                                             action:@selector(sendClipboard:)]];
    [stack addArrangedSubview:[self buttonWithTitle:@"Unpair"
                                             action:@selector(unpair:)]];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(devicesChanged:)
                                                 name:KDECServiceDevicesDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(fileReceived:)
                                                 name:KDECServiceFileReceivedNotification
                                               object:nil];
    [self updateStatus];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(12, 16, 12, 16);
    button.layer.borderWidth = 1;
    button.layer.cornerRadius = 6;
    button.layer.borderColor = [UIColor lightGrayColor].CGColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)devicesChanged:(NSNotification *)notification
{
    [self updateStatus];
}

- (void)updateStatus
{
    self.statusLabel.text = self.device.reachable ? @"Connected" : @"Offline";
}

- (void)fileReceived:(NSNotification *)notification
{
    self.activityLabel.text = [NSString stringWithFormat:@"Received %@",
                               [notification.userInfo[@"path"] lastPathComponent]];
}

- (void)sendClipboard:(id)sender
{
    [[KDECService shared] sendClipboardToDevice:self.device];
}

- (void)sendFile:(id)sender
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                                              initWithDocumentTypes:@[@"public.data"]
                                              inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }
    [url startAccessingSecurityScopedResource];
    BOOL sent = [[KDECService shared] sendFileAtPath:url.path toDevice:self.device];
    [url stopAccessingSecurityScopedResource];
    self.activityLabel.text = sent ? @"File queued" : @"Could not send file";
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)unpair:(id)sender
{
    [[KDECService shared] unpairDevice:self.device];
    [self.navigationController popViewControllerAnimated:YES];
}

@end
