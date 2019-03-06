//
//  PaperTrailLumberJack.m
//  PaperTrailLumberJack
//
//  Created by Malayil Philip George on 5/1/14.
//  Copyright (c) 2014 Rogue Monkey Technologies & Systems Private Limited. All rights reserved.
//

#import "RMPaperTrailLogger.h"
#import "RMSyslogFormatter+Private.h"

static NSTimeInterval const kDefaultBaseWaitTime = 30.0; // 30 seconds
static NSTimeInterval const kDefaultMaxBackOffTime = 60.0 * 10.0; // 10 minutes
static NSUInteger const kDefaultMaxInflightCount = 30; // 10 minutes
static NSTimeInterval const kDefaultInFlightTTL = 60.0 * 2.0; // 2 minutes
static NSTimeInterval const kDefaultInFlightPurgeFrequency = 60.0 * 2.0; // 2 minutes


@interface RMPaperTrailLogger () {
    GCDAsyncSocket *_tcpSocket;
    GCDAsyncUdpSocket *_udpSocket;
    NSTimeInterval _waitTimeBase;
    NSTimeInterval _maxWaitTime;
    NSDate *_timeOfNextExecution;
    NSUInteger _failedAttempts;
    NSMutableArray *_inFlightDates;
    NSUInteger _maxInFlightCount;
    NSTimer *_cleanUpTimer;
    NSTimeInterval _inFlightTTL;
    NSTimeInterval _inFlightPurgeFrequency;
    NSMutableDictionary *_tagToDate;
}

@property (nonatomic, strong) GCDAsyncSocket *tcpSocket;
@property (nonatomic, strong) GCDAsyncUdpSocket *udpSocket;
@property (nonatomic, assign) NSTimeInterval waitTimeBase;
@property (nonatomic, assign) NSTimeInterval maxWaitTime;
@property (nonatomic, strong) NSDate *timeOfNextExecution;
@property (nonatomic, assign) NSUInteger failedAttempts;
@property (nonatomic, strong) NSMutableArray *inFlightDates;
@property (nonatomic, strong) NSMutableDictionary *tagToDate;
@property (nonatomic, assign) NSUInteger maxInFlightCount;
@property (nonatomic, strong) NSTimer *cleanUpTimer;
@property (nonatomic, assign) NSTimeInterval inFlightTTL;
@property (nonatomic, assign) NSTimeInterval inFlightPurgeFrequency;

@end

@implementation RMPaperTrailLogger

@synthesize host = _host;
@synthesize port = _port;
@synthesize useTcp = _useTcp;
@synthesize useTLS = _useTLS;

@synthesize tcpSocket = _tcpSocket;
@synthesize udpSocket = _udpSocket;

+(RMPaperTrailLogger *) sharedInstance
{
    static dispatch_once_t pred = 0;
    static RMPaperTrailLogger *_sharedInstance = nil;
    
    dispatch_once(&pred, ^{
        _sharedInstance = [[self alloc] init];
        RMSyslogFormatter *logFormatter = [[RMSyslogFormatter alloc] init];
        _sharedInstance.logFormatter = logFormatter;
        _sharedInstance.useTcp = YES;
        _sharedInstance.useTLS = YES;
        _sharedInstance.waitTimeBase = kDefaultBaseWaitTime;
        _sharedInstance.maxWaitTime = kDefaultMaxBackOffTime;
        _sharedInstance.failedAttempts = 0;
        _sharedInstance.maxInFlightCount = kDefaultMaxInflightCount;
        _sharedInstance.timeOfNextExecution = nil;
        _sharedInstance.inFlightDates = [[NSMutableArray alloc] init];
        _sharedInstance.inFlightTTL = kDefaultInFlightTTL;
        _sharedInstance.inFlightPurgeFrequency = kDefaultInFlightPurgeFrequency;
        _sharedInstance.tagToDate = [[NSMutableDictionary alloc] init];
    });
    
    return _sharedInstance;
}

-(void) dealloc {
    [self disconnect];
}

#pragma mark - Accessors
-(void) setMachineName:(NSString *)machineName
{
    _machineName = machineName;
    if ([self.logFormatter isKindOfClass:[RMSyslogFormatter class]]) {
        RMSyslogFormatter* syslogFormatter = (RMSyslogFormatter*)_logFormatter;
        syslogFormatter.machineName = machineName;
    }
}

-(void) setProgramName:(NSString *)programName
{
    _programName = programName;
    if ([self.logFormatter isKindOfClass:[RMSyslogFormatter class]]) {
        RMSyslogFormatter* syslogFormatter = (RMSyslogFormatter*)_logFormatter;
        syslogFormatter.programName = programName;
    }
}

#pragma mark - Networking Implementation
-(void) disconnect
{
    if (self.tcpSocket != nil) {
        [self.tcpSocket disconnect];
        self.tcpSocket = nil;
    } else if (self.udpSocket != nil) {
        [self.udpSocket close];
        self.udpSocket = nil;
    }
}

-(void) logMessage:(DDLogMessage *)logMessage
{
#ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Entered logMessage");
#endif
    if (self.host == nil || self.host.length == 0 || self.port == 0 || [self shouldBackoff] || [self shouldThrottle]) {
#ifdef DEBUG
        NSLog(@"RMPaperTrailLogger Exiting logMessage early.");
#endif
        return;
    }
    
    NSString *logMsg = logMessage.message;
    if (logMsg == nil) {
        logMsg = @"";
    }
    
    if (_logFormatter) {
        logMsg = [_logFormatter formatLogMessage:logMessage];
    }
    
    //Check if last character is newLine
    unichar lastChar = [logMsg characterAtIndex:logMsg.length-1];
    if (![[NSCharacterSet newlineCharacterSet] characterIsMember:lastChar]) {
        logMsg = [NSString stringWithFormat:@"%@\n", logMsg];
    }
    //
    NSDate *inFlightDate = [self addToInflightArray];
    NSNumber *tagNumber = [self addTagToDate:inFlightDate];
    long tag = [tagNumber longValue];
    
    if (!self.useTcp) {
        [self sendLogOverUdp:logMsg tag:tag];
    } else {
        [self sendLogOverTcp:logMsg tag:tag];
    }
}

-(void) sendLogOverUdp:(NSString *) message
                   tag:(long)tag
{
#ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Entered logMessage");
#endif
    if (message == nil || message.length == 0)
        return;
    
    if (self.udpSocket == nil) {
        GCDAsyncUdpSocket *udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
        self.udpSocket = udpSocket;
    }
    
    NSData *logData = [message dataUsingEncoding:NSUTF8StringEncoding];
    
    [self.udpSocket sendData:logData toHost:self.host port:self.port withTimeout:-1 tag:tag];
}

-(void) sendLogOverTcp:(NSString *) message
                   tag:(long)tag
{
    if (message == nil || message.length == 0)
        return;
    
    @synchronized(self) {
        if (self.tcpSocket == nil) {
            GCDAsyncSocket *tcpSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
            self.tcpSocket = tcpSocket;
            [self connectTcpSocket];
        }
    }
    
    NSData *logData = [message dataUsingEncoding:NSUTF8StringEncoding];
    [self.tcpSocket writeData:logData withTimeout:-1 tag:tag];
}

-(void) connectTcpSocket
{
    if (self.host == nil || self.port == 0)
        return;
    
    NSError *error = nil;
    [self.tcpSocket connectToHost:self.host onPort:self.port error:&error];
    if (error != nil) {
        NSLog(@"Error connecting to host: %@", error);
        return;
    }
    
    if (self.useTLS) {
#ifdef DEBUG
        NSLog(@"RMPaperTrailLogger Starting TLS");
#endif
        [self.tcpSocket startTLS:nil];
    }
}

#pragma mark - GCDAsyncDelegate methods



- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port
{
    #ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Socket did connect to host");
    #endif
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock
{
    #ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Socket did secure");
    #endif
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error
{
    #ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Socket did disconnect. Error: %@", error);
    #endif
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    #ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Socket did write data");
    #endif
    [self resetBackoff];
    [self removeTagFromInflight: tag];
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didSendDataWithTag:(long)tag
{
    #ifdef DEBUG
    NSLog(@"RMPaperTrailLogger UDP Socket did write data");
    #endif
    [self resetBackoff];
    [self removeTagFromInflight: tag];
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error
{
    #ifdef DEBUG
    NSLog(@"RMPaperTrailLogger UDP Socket Error: %@", error.localizedDescription);
    #endif
    [self backoff];
    [self removeTagFromInflight: tag];
}

-(void) removeTagFromInflight:(long)tag {
    @synchronized (self) {
        NSNumber *key = @(tag);
        NSDate *date = self.tagToDate[key];
        if (date == nil) {
            return;
        }
        [self.inFlightDates removeObject:date];
        [self.tagToDate removeObjectForKey:key];
    }
}

-(void)backoff {
#ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Entered backoff");
#endif
    @synchronized (self) {
        NSTimeInterval currentTimeInterval = MIN(pow(2.0, self.failedAttempts) * self.waitTimeBase, self.maxWaitTime);
        self.timeOfNextExecution = [[NSDate date] dateByAddingTimeInterval:currentTimeInterval];
        self.failedAttempts++;
        NSLog(@"RMPaperTrailLogger failedAttempts: %lu timeOfNextExecution: %@", (unsigned long)self.failedAttempts, self.timeOfNextExecution);
    }
}

-(void)resetBackoff {
#ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Entered resetBackoff");
#endif
    @synchronized (self) {
        self.timeOfNextExecution = nil;
        self.failedAttempts = 0;
    }
}

-(BOOL)shouldBackoff {
#ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Entered shouldBackoff");
#endif
    @synchronized (self) {
        if (self.timeOfNextExecution == nil) {
            return NO;
        }
        NSDate *now = [NSDate date];
        BOOL result = [now isEqualToDate:[now earlierDate:self.timeOfNextExecution]];
#ifdef DEBUG
        NSLog(@"RMPaperTrailLogger shouldBackoff Result: %hhd", result);
#endif
        return result;
    }
}

-(BOOL)shouldThrottle {
#ifdef DEBUG
    NSLog(@"RMPaperTrailLogger Entered shouldThrottle");
#endif
    @synchronized (self) {
        BOOL result = self.inFlightDates.count >= self.maxInFlightCount;
#ifdef DEBUG
        NSLog(@"RMPaperTrailLogger shouldThrottle Result: %hhd", result);
#endif
        return result;
    }
}

-(void)cleanupInFlightArray {
    @synchronized (self) {
        if (!self.inFlightDates || !self.inFlightDates.count) {
            [self stopCleanupTimer];
            return;
        }
        NSDate *now = [NSDate date];
        NSDate *cutoffDate = [now dateByAddingTimeInterval: -1.0 * fabs(self.inFlightTTL)];
        NSPredicate *entriesOlderThanCutoff = [NSPredicate predicateWithFormat:@"self <= %@", cutoffDate];
        NSArray *datesToRemove = [self.inFlightDates filteredArrayUsingPredicate:entriesOlderThanCutoff];
        [self.inFlightDates removeObjectsInArray:datesToRemove];
        [self removeDatesFromTagToDate: datesToRemove];
        if (!self.inFlightDates || !self.inFlightDates.count) {
            [self stopCleanupTimer];
        }
    }
}

-(void)removeDatesFromTagToDate:(NSArray *)datesToRemove {
    for (NSDate *date in datesToRemove) {
        NSArray *keysToRemove = [self.tagToDate allKeysForObject:date];
        [self.tagToDate removeObjectsForKeys:keysToRemove];
    }
}

-(NSDate *)addToInflightArray {
    @synchronized (self) {
        NSDate *date = [NSDate date];
        [self.inFlightDates addObject:date];
        if (self.cleanUpTimer == nil) {
            self.cleanUpTimer = [NSTimer scheduledTimerWithTimeInterval:self.inFlightPurgeFrequency
                                                                 target:self
                                                               selector:@selector(cleanupInFlightArray)
                                                               userInfo:nil
                                                                repeats:true];
        }
        return date;
    }
}

-(void)removeFromInflightArray {
    @synchronized (self) {
        if (self.inFlightDates.count > 0) {
            [self.inFlightDates removeObjectAtIndex:0];
        } else {
            [self stopCleanupTimer];
            [self.tagToDate removeAllObjects];
        }
    }
}

-(void)stopCleanupTimer {
    [self.cleanUpTimer invalidate];
    self.cleanUpTimer = nil;
}

-(NSNumber *)addTagToDate: (NSDate *)date {
    @synchronized (self) {
        NSNumber *key = @(self.tagToDate.count);
        self.tagToDate[key] = date;
        return key;
    }
}

@end
