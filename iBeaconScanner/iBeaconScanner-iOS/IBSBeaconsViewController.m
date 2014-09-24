//
//  IBSBeaconsViewController.m
//  iBeaconScanner-iOS
//
//  Created by Tim Kersey on 3/10/14.
//  Copyright (c) 2014 Tim Kersey. All rights reserved.
//

@import CoreBluetooth;
#import "IBSBeaconsViewController.h"

static const NSTimeInterval kScanTimeInterval = 1.0;

@interface IBSBeaconsViewController () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (strong, nonatomic) CBCentralManager *manager;
@property (strong, nonatomic) NSMutableArray *beacons;
@property (strong, nonatomic) NSMutableDictionary *foundBeacons;
@property (nonatomic) BOOL canScan;
@property (nonatomic) BOOL isScanning;
@property (strong, nonatomic) NSTimer *scanTimer;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) BOOL hasScanned;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *searchForBeaconsButton;
@end

@implementation IBSBeaconsViewController

#pragma mark - View Lifecycle

- (void)awakeFromNib {
    self.manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
}

- (void)viewDidLoad {
    self.foundBeacons= [NSMutableDictionary dictionary];
    [super viewDidLoad];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

#pragma mark - CBCentral Manager Delegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    self.canScan = self.manager.state == CBCentralManagerStatePoweredOn ?: NO;

    switch (central.state) {
        case CBCentralManagerStatePoweredOff:
            self.title = @"Powered Off";
            break;
        case CBCentralManagerStatePoweredOn:
            self.title = @"Powered On";
            break;
        case CBCentralManagerStateResetting:
            self.title = @"Resetting";
            break;
        case CBCentralManagerStateUnauthorized:
            self.title = @"Unauthorized";
            break;
        case CBCentralManagerStateUnsupported:
            self.title = @"Unsupported";
            break;
        case CBCentralManagerStateUnknown:
        default:
            self.title = @"Unknown";
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    NSLog(@"Advertising Data: %@", advertisementData);
    NSData *advData = advertisementData[@"kCBAdvDataManufacturerData"];
    NSMutableDictionary *beacon = [[self getBeaconInfoFromData:advData] mutableCopy];
    
    beacon[@"RSSI"] = RSSI;
    
    beacon[@"deviceUUID"] = peripheral.identifier.UUIDString;
    
    NSNumber *distance = [self calculatedDistance:beacon[@"power"] RSSI:RSSI];
    if (distance) beacon[@"distance"] = distance;
    
    beacon[@"proximity"] = [self proximityFromDistance:distance];
    
    NSString *uniqueUUID = peripheral.identifier.UUIDString;
    if (beacon[@"uuid"]) uniqueUUID = [uniqueUUID stringByAppendingString:beacon[@"uuid"]];
    
    self.foundBeacons[uniqueUUID] = beacon;
}

#pragma mark - Beacon scanning

- (BOOL)startScanning {
    if (self.canScan) {
        if (self.scanTimer) [self.scanTimer invalidate];
        if (self.hasScanned && self.duration < 5) self.duration += kScanTimeInterval;
        else self.duration = kScanTimeInterval;
        self.isScanning = YES;

        [self.manager scanForPeripheralsWithServices:nil options:nil];
        self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:self.duration target:self selector:@selector(timerDidFire) userInfo:nil repeats:NO];
        NSLog(@"Started Scanning");
        return YES;
    }
    NSLog(@"Unable to starting scanning");
    return NO;
}

- (void)stopScanning {
    [self.manager stopScan];
    self.hasScanned = YES;
    self.isScanning = NO;
    [self.scanTimer invalidate];
}

- (void)timerDidFire {
    NSLog(@"Found Beacons during scan: %@", [self.foundBeacons allValues]);
    self.beacons = [[self.foundBeacons allValues] mutableCopy];
    [self.foundBeacons removeAllObjects];
    [self stopScanning];
    [self.tableView reloadData];
}

#pragma mark - Button management

- (IBAction)searchForBeacons:(id)sender {
    [self startScanning];
}

- (void)setIsScanning:(BOOL)isScanning {
    if (_isScanning != isScanning) _isScanning = isScanning;
    self.searchForBeaconsButton.enabled = self.canScan;
}

- (void)setCanScan:(BOOL)canScan {
    if (_canScan != canScan) _canScan = canScan;
    self.searchForBeaconsButton.enabled = self.canScan;
}

#pragma mark - Working with Beacon data

- (BOOL)advertisementDataIsBeacon:(NSData *)data {
    Byte expectingBytes[4] = {0x4c, 0x00, 0x02, 0x15};
    NSData *expectingData = [NSData dataWithBytes:expectingBytes length:sizeof(expectingBytes)];
    if (data.length > expectingData.length && [[data subdataWithRange:NSMakeRange(0, expectingData.length)] isEqualToData:expectingData]) {
        return YES;
    }
    return NO;
}

- (NSDictionary *)getBeaconInfoFromData:(NSData *)data {
    NSRange uuidRange = NSMakeRange(4, 16);
    NSRange majorRange = NSMakeRange(20, 2);
    NSRange minorRange = NSMakeRange(22, 2);
    NSRange powerRange = NSMakeRange(24, 1);

    Byte uuidBytes[16];
    [data getBytes:&uuidBytes range:uuidRange];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:uuidBytes];
    
    uint16_t majorBytes;
    [data getBytes:&majorBytes range:majorRange];
    uint16_t majorBytesBig = (majorBytes >> 8) | (majorBytes << 8);
    
    uint16_t minorBytes;
    [data getBytes:&minorBytes range:minorRange];
    uint16_t minorBytesBig = (minorBytes >> 8) | (minorBytes << 8);
    
    int8_t powerByte;
    [data getBytes:&powerByte range:powerRange];
    
    return @{@"uuid" : uuid.UUIDString, @"major" : @(majorBytesBig), @"minor" : @(minorBytesBig), @"power" : @(powerByte)};
}

- (NSNumber *)calculatedDistance:(NSNumber *)txPowerNum RSSI:(NSNumber *)RSSINum {
    int txPower = [txPowerNum intValue];
    double rssi = [RSSINum doubleValue];
    
    if (rssi == 0) return nil; // if we cannot determine accuracy, return nil.
    
    double ratio = rssi * 1.0 / txPower;
    if (ratio < 1.0) return @(pow(ratio, 10.0));
    else return @(0.89976 * pow(ratio, 7.7095) + 0.111);
}

- (NSString *)proximityFromDistance:(NSNumber *)distance {
    if (distance == nil) distance = @(-1);

    if (distance.doubleValue >= 2.0) return @"Far";
    if (distance.doubleValue >= 0.25) return @"Near";
    if (distance.doubleValue >= 0) return @"immediate";
    return @"Unknown";
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.beacons.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"beaconCell" forIndexPath:indexPath];
    cell.textLabel.text = self.beacons[indexPath.row][@"deviceUUID"];
    return cell;
}

@end
