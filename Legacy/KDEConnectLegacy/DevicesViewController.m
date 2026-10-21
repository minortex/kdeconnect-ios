//
//  DevicesViewController.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "DevicesViewController.h"
#import "DeviceViewController.h"
#import "KDECDeviceInfo.h"
#import "KDECService.h"

@implementation DevicesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"KDE Connect";
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self
                            action:@selector(refresh:)
                  forControlEvents:UIControlEventValueChanged];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(devicesChanged:)
                                                 name:KDECServiceDevicesDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pairRequested:)
                                                 name:KDECServicePairRequestNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [[KDECService shared] refresh];
}

- (void)refresh:(id)sender
{
    [[KDECService shared] refresh];
    [self.refreshControl endRefreshing];
}

- (void)devicesChanged:(NSNotification *)notification
{
    [self.tableView reloadData];
}

- (void)pairRequested:(NSNotification *)notification
{
    KDECDeviceInfo *device = notification.object;
    UIAlertController *alert = [UIAlertController
                                alertControllerWithTitle:@"Pair device"
                                message:[NSString stringWithFormat:@"Pair with \"%@\"?", device.name]
                                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Pair"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [[KDECService shared] acceptPairingForDevice:device];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        [[KDECService shared] rejectPairingForDevice:device];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self devicesForSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"Paired" : @"Available";
}

- (NSArray<KDECDeviceInfo *> *)devicesForSection:(NSInteger)section
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"paired == %@", @(section == 0)];
    return [[KDECService shared].devices filteredArrayUsingPredicate:predicate];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DeviceCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"DeviceCell"];
    }
    KDECDeviceInfo *device = [self devicesForSection:indexPath.section][indexPath.row];
    cell.textLabel.text = device.name;
    cell.detailTextLabel.text = device.reachable ? @"Connected" : @"Offline";
    cell.accessoryType = device.paired ? UITableViewCellAccessoryDisclosureIndicator
                                       : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    KDECDeviceInfo *device = [self devicesForSection:indexPath.section][indexPath.row];
    if (!device.paired) {
        [[KDECService shared] pairDevice:device];
        return;
    }
    DeviceViewController *controller = [[DeviceViewController alloc] initWithDevice:device];
    [self.navigationController pushViewController:controller animated:YES];
}

@end
