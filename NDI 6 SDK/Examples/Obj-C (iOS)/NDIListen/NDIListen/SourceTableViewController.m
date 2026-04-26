//
//  SourceTableViewController.m
//  SimpleNDI
//
//  Created by Mike Watkins on 3/27/19.
//  Copyright © 2019 NewTek. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SourceTableViewController.h"

// My AppDelegate class
#import "AppDelegate.h"

// The audio playback class
#import "AudioPlayback.h"

@interface SourceTableViewController () {
    AppData *_theModel;
}

@end

@implementation SourceTableViewController

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
    return [_theModel.currHostSourceList count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    
    static NSString *CellIdentifier = @"SourceCell";
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    // Configure the cell.
    NDISourceDesc *ndiSrcDesc = [_theModel.currHostSourceList objectAtIndex:[indexPath row]];
    cell.textLabel.text = ndiSrcDesc.friendlyName;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    
    NSInteger idx = [indexPath indexAtPosition:indexPath.length - 1];
    NDISourceDesc *ndiSrcDesc = [_theModel.currHostSourceList objectAtIndex:idx];
    
    [_theModel setNDISourceInfoNamed:ndiSrcDesc.fullName LocatedAt:ndiSrcDesc.urlAddy];
    if (_theModel.audioPlayer == nil)
    {
        _theModel.audioPlayer = [[AudioPlayback alloc] init];
         _theModel.audioPlayer.sourceChangedCounter = _theModel.selectedNDISourceChangedCount;
    }
}

@end
