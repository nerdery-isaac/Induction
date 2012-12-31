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
@end

@implementation EMFConnectionConfigurationViewController
@synthesize delegate = _delegate;
@synthesize connectionURL = _connectionURL;
@synthesize connecting = _connecting;
@dynamic isConnecting;
@synthesize URLField = _URLField;
@synthesize schemePopupButton = _schemePopupButton;
@synthesize hostnameField = _hostnameField;
@synthesize usernameField = _usernameField;
@synthesize passwordField = _passwordField;
@synthesize portField = _portField;
@synthesize databaseField = _databaseField;
@synthesize connectButton = _connectButton;
@synthesize connectionProgressIndicator = _connectionProgressIndicator;

- (void)awakeFromNib {
    self.schemePopupButton.target = self;
    self.schemePopupButton.action = @selector(schemePopupButtonDidChange:);
    
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
    
    // TODO Make less hacky
//    [self.schemePopupButton selectItemWithTitle:[self.connectionURL scheme]];
    
    [self.URLField becomeFirstResponder];
}

#pragma mark - IBAction

- (void)connect:(id)sender {    
    NSLog(@"URL: %@", self.connectionURL);
    
    self.connecting = YES;

    for (NSString *path in [[NSBundle mainBundle] pathsForResourcesOfType:@"bundle" inDirectory:@"../PlugIns/Adapters"]) {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        [bundle loadAndReturnError:nil];
        
        if ([[bundle principalClass] conformsToProtocol:@protocol(DBAdapter)]) {
            id <DBAdapter> adapter = (id <DBAdapter>)[bundle principalClass];
            if ([adapter canConnectToURL:self.connectionURL]) {
                [adapter connectToURL:self.connectionURL success:^(id <DBConnection> connection) {
                    [[NSUserDefaults standardUserDefaults] setURL:self.connectionURL forKey:kInductionPreviousConnectionURLKey];
                    [self.delegate connectionConfigurationController:self didConnectWithConnection:connection];
                } failure:^(NSError *error){
                    self.connecting = NO;
                    
                    [self presentError:error modalForWindow:self.view.window delegate:nil didPresentSelector:nil contextInfo:nil];
                }];
                
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

- (void)schemePopupButtonDidChange:(id)sender {
    self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents([self.schemePopupButton titleOfSelectedItem], [self.hostnameField stringValue], [self.usernameField stringValue], [self.passwordField stringValue], [NSNumber numberWithInteger:[self.portField integerValue]], [self.databaseField stringValue])];
    [[self.portField cell] setPlaceholderString:[self defaultPortStringForDatabaseScheme:[self.schemePopupButton titleOfSelectedItem]]];
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
            scheme = [[self.schemePopupButton selectedCell] title];
        }
        
        NSString *password = [url password];
        if (!password) {
            password = [self.passwordField objectValue];
        }
        
        self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents(scheme, [url host], [url user], password, [url port], [url path])];
    } else {
        self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents([[self.schemePopupButton selectedCell] title], [self.hostnameField stringValue], [self.usernameField stringValue], [self.passwordField stringValue], [NSNumber numberWithInteger:[self.portField integerValue]], [self.databaseField stringValue])];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSControl *control = [notification object];
    
    if ([control isEqual:self.URLField]) {
        NSURL *url = [NSURL URLWithString:[self.URLField stringValue]];
        
        [self.schemePopupButton selectItemWithTitle:[url scheme]];
        
        self.connectionURL = [NSURL URLWithString:DBURLStringFromComponents([self.schemePopupButton titleOfSelectedItem], [self.hostnameField stringValue], [self.usernameField stringValue], [self.passwordField stringValue], [NSNumber numberWithInteger:[self.portField integerValue]], [self.databaseField stringValue])];
        
        [[self.portField cell] setPlaceholderString:[self defaultPortStringForDatabaseScheme:[url scheme]]];
    }
}


@end
