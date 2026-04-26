//
//  HostTableViewController.m
//  SimpleNDI
//
//  Created by Mike Watkins on 3/26/19.
//  Copyright © 2019 NewTek. All rights reserved.
//

#import "HostTableViewController.h"

// My AppDelegate class
#import "AppDelegate.h"

@interface HostTableViewController () {
    AppData *_theModel;
}

@end

@implementation HostTableViewController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if (self = [super initWithStyle:style])
    {
        _theModel = [AppData inst];
    }
    return self;
}
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil {
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])
    {
        _theModel = [AppData inst];
    }
    return self;
}
- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder])
    {
        _theModel = [AppData inst];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_theModel.hostList count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    
    static NSString *CellIdentifier = @"HostCell";
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    // Configure the cell.
    cell.textLabel.text = [_theModel.hostList objectAtIndex:[indexPath row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    
    NSInteger idx = [indexPath indexAtPosition:indexPath.length - 1];
    _theModel.currHostSourceList = [_theModel.hostSourceList objectAtIndex:idx];
    
    [self performSegueWithIdentifier:@"showSourcesSegue" sender:self];
}

- (IBAction)OnRefreshSources:(id)sender {
    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    [appDelegate findSources];
    
    UITableView *tableView = (UITableView*)self.view;
    [tableView reloadData];
}
@end
