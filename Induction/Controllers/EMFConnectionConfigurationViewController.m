// EMFConnectionConfigurationViewController.m
//
// Copyright (c) 2012 Mattt Thompson (http://mattt.me)
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
#import "EMFConnectionConfigurationViewController.h"
#import "SPSSHTunnel.h"

static NSString * const kInductionPreviousConnectionURLKey = @"com.induction.connection.previous.url";

static NSString * DBURLStringFromComponents(NSString *scheme, NSString *host, NSString *user, NSString *password, NSNumber *port, NSString *database) {
    NSMutableString *mutableURLString = [NSMutableString stringWithFormat:@"%@://", scheme];
    if (user && [user length] > 0) {
        [mutableURLString appendFormat:@"%@", user];
        if (password && [password length] > 0) {
            [mutableURLString appendFormat:@":%@", password];
        }
        [mutableURLString appendString:@"@"];
    }
    
    if (host && [host length] > 0) {
        [mutableURLString appendString:host];
    }
    
    if (port && [port integerValue] > 0) {
        [mutableURLString appendFormat:@":%ld", [port integerValue]];
    }
    
    if (database && [database length] > 0 && [host length] > 0) {
        [mutableURLString appendFormat:@"/%@", [database stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];
    }
    
    return [NSString stringWithString:mutableURLString];
}

#pragma mark -

@interface EMFDatabaseParameterFormatter : NSFormatter
@end

@implementation EMFDatabaseParameterFormatter

- (NSString *)stringForObjectValue:(id)obj {
    if (![obj isKindOfClass:[NSString class]]) {
        return nil;
    }
    
    return [obj stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
}

- (BOOL)getObjectValue:(__autoreleasing id *)obj forString:(NSString *)string errorDescription:(NSString *__autoreleasing *)error {
    if(obj) {
        *obj = string;
    }
    
    return YES;
}

- (BOOL)isPartialStringValid:(NSString *)partialString newEditingString:(NSString *__autoreleasing *)newString errorDescription:(NSString *__autoreleasing *)error {
    static NSCharacterSet *_illegalDatabaseParameterCharacterSet = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _illegalDatabaseParameterCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@" ,:;@!#$%&^'()[]{}\"\\/|"];
    });
    
    return [partialString rangeOfCharacterFromSet:_illegalDatabaseParameterCharacterSet].location == NSNotFound;
}

@end

#pragma mark -

@interface DBRemovePasswordURLValueTransformer : NSValueTransformer
@end

@implementation DBRemovePasswordURLValueTransformer

+ (Class)transformedValueClass {
    return [NSURL class];
}

+ (BOOL)allowsReverseTransformation {
    return NO;
}

- (id)transformedValue:(id)value {
    if (!value) {
        return nil;
    }
    
    NSURL *url = (NSURL *)value;
    
    return [NSURL URLWithString:DBURLStringFromComponents([url scheme], [url host], [url user], nil, [url port], [url path])];
}

@end

#pragma mark -

@interface EMFConnectionConfigurationViewController ()
@property (readwrite, nonatomic, getter = isConnecting) BOOL connecting;
@property (nonatomic, strong) SPSSHTunnel *sshTunnel;
@end

@implementation EMFConnectionConfigurationViewController
@synthesize delegate = _delegate;
@synthesize connectionURL = _connectionURL;
@synthesize connecting = _connecting;
@dynamic isConnecting;
@synthesize URLField = _URLField;
@synthesize schemePopupButton = _schemePopupButton;
@synthesize portField = _portField;
@synthesize connectButton = _connectButton;
@synthesize connectionProgressIndicator = _connectionProgressIndicator;

- (void)awakeFromNib {
    for (NSString *path in [[NSBundle mainBundle] pathsForResourcesOfType:@"bundle" inDirectory:@"../PlugIns/Adapters"]) {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        [bundle loadAndReturnError:nil];
        
        if ([[bundle principalClass] conformsToProtocol:@protocol(DBAdapter)]) {
            [self.schemePopupButton addItemWithTitle:[[bundle principalClass] primaryURLScheme]];
        }
    }

    // TODO Check against registered adapters to detect appropriate URL on pasteboard
    NSURL *pasteboardURL = [NSURL URLWithString:[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString]];
    if (pasteboardURL && [[pasteboardURL scheme] length] > 0 && ![[pasteboardURL scheme] hasPrefix:@"http"]) {
        self.connectionURL = pasteboardURL;
    } else {
        self.connectionURL = [[NSUserDefaults standardUserDefaults] URLForKey:kInductionPreviousConnectionURLKey];
    }
    
    self.urlString = self.connectionURL.absoluteString;
    self.scheme = self.connectionURL.scheme;
    self.hostname = self.connectionURL.host;
    self.username = self.connectionURL.user;
    self.password = self.connectionURL.password;
    self.port = self.connectionURL.port;
    self.database = self.connectionURL.path;
    [[self.portField cell] setPlaceholderString:[self defaultPortStringForDatabaseScheme:self.scheme]];
    
    [self.URLField becomeFirstResponder];
}

#pragma mark - IBAction

- (void)connect:(id)sender {    
    self.connecting = YES;

    for (NSString *path in [[NSBundle mainBundle] pathsForResourcesOfType:@"bundle" inDirectory:@"../PlugIns/Adapters"]) {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        [bundle loadAndReturnError:nil];
        
        if ([[bundle principalClass] conformsToProtocol:@protocol(DBAdapter)]) {
            id <DBAdapter> adapter = (id <DBAdapter>)[bundle principalClass];
            if ([adapter canConnectToURL:self.connectionURL]) {
                self.sshTunnel = [[SPSSHTunnel alloc]
                                  initToHost:self.sshHostname
                                  port:self.sshPort.unsignedIntegerValue
                                  login:self.sshUsername
                                  tunnellingToPort:self.port.unsignedIntegerValue ? self.port.unsignedIntegerValue : [self defaultPortStringForDatabaseScheme:self.scheme].integerValue
                                  onHost:self.hostname];
                [self.sshTunnel setParentWindow:self.view.window];
                __weak EMFConnectionConfigurationViewController *weakSelf = self;
                [self.sshTunnel setStateChangeBlock:^(SPSSHTunnel *theTunnel) {
                    //        if (cancellingConnection) return;
                    
                    NSInteger newState = [theTunnel state];
                    
                    // If the user cancelled the password prompt dialog, continue with no further action.
                    if ([theTunnel passwordPromptCancelled]) {
                        //            [self _restoreConnectionInterface];
                        
                        return;
                    }
                    
                    if (newState == SPMySQLProxyIdle) {
                        
                        // If the connection closed unexpectedly, and muxing was enabled, disable muxing an re-try.
                        if ([theTunnel taskExitedUnexpectedly] && [theTunnel connectionMuxingEnabled]) {
                            [theTunnel setConnectionMuxingEnabled:NO];
                            [theTunnel connect];
                            return;
                        }
                        
                        //            [[self onMainThread] failConnectionWithTitle:NSLocalizedString(@"SSH connection failed!", @"SSH connection failed title") errorMessage:[theTunnel lastError] detail:[sshTunnel debugMessages] rawErrorText:[theTunnel lastError]];
                    } else if (newState == SPMySQLProxyConnected) {
                        NSURL *newUrl = [NSURL URLWithString:DBURLStringFromComponents(self.scheme, @"127.0.0.1", self.username, self.password, @(theTunnel.localPort), self.database)];
                        [adapter connectToURL:newUrl success:^(id <DBConnection> connection) {
                            [[NSUserDefaults standardUserDefaults] setURL:self.connectionURL forKey:kInductionPreviousConnectionURLKey];
                            [self.delegate connectionConfigurationController:weakSelf didConnectWithConnection:connection];
                        } failure:^(NSError *error){
                            self.connecting = NO;
                            
                            [weakSelf presentError:error modalForWindow:self.view.window delegate:nil didPresentSelector:nil contextInfo:nil];
                        }];
                    } else {
                    }
                }];
                [self.sshTunnel connect];
                
                break;
            }
        }
    }
}

- (void)setConnecting:(BOOL)connecting {
    _connecting = connecting;
    
    if ([self isConnecting]) {
        [self.connectionProgressIndicator startAnimation:self];
    } else {
        [self.connectionProgressIndicator stopAnimation:self];
    }
}

#pragma mark -

- (NSString *)defaultPortStringForDatabaseScheme:(NSString *)scheme
{
    if ([scheme isEqualToString:@"postgres"]) {
        return @"5432";
    }
    if ([scheme isEqualToString:@"mysql"]) {
        return @"3306";
    }
    if ([scheme isEqualToString:@"mongodb"]) {
        return @"27017";
    }
    return nil;
}

- (IBAction)schemePopupButtonDidChange:(id)sender {
    self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents(self.scheme, self.hostname, self.username, self.password, self.port, self.database)];
    [[self.portField cell] setPlaceholderString:[self defaultPortStringForDatabaseScheme:self.scheme]];
}

#pragma mark - NSControl Delegate Methods

- (void)controlTextDidBeginEditing:(NSNotification *)notification {
    NSControl *control = [notification object];
    [control unbind:@"objectValue"];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    NSControl *control = [notification object];
    
    if ([control isEqual:self.URLField]) {
        NSURL *url = [NSURL URLWithString:[self.URLField stringValue]];
        
        NSString *scheme = [url scheme];
        if (!scheme) {
            scheme = self.scheme;
        }
        
        NSString *password = [url password];
        if (!password) {
            password = self.password;
        }
        
        self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents(scheme, [url host], [url user], password, [url port], [url path])];
    } else {
        self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents(self.scheme, self.hostname, self.username, self.password, self.port, self.database)];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSControl *control = [notification object];
    
    if ([control isEqual:self.URLField]) {
        NSURL *url = [NSURL URLWithString:[self.URLField stringValue]];
        
        self.scheme = [url scheme];
        
        self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents(self.scheme, self.hostname, self.username, self.password, self.port, self.database)];
        
        [[self.portField cell] setPlaceholderString:[self defaultPortStringForDatabaseScheme:[url scheme]]];
    }
}


@end
