#import "HTTPConnection.h"

@implementation HTTPConnection

@synthesize airplaydelegate;

- (id)init {
    [self dealloc];
    return nil;
}

- (id)initWithPeerAddress:(NSData *)addr inputStream:(NSInputStream *)istr outputStream:(NSOutputStream *)ostr forServer:(HTTPServer *)serv {
    peerAddress = [addr copy];
    server = serv;
    istream = [istr retain];
    ostream = [ostr retain];
    [istream setDelegate:self];
    [ostream setDelegate:self];
    [istream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:(id)kCFRunLoopCommonModes];
    [ostream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:(id)kCFRunLoopCommonModes];
    [istream open];
    [ostream open];
    isValid = YES;
    return self;
}

- (void)dealloc {
    [self invalidate];
    [peerAddress release];
    [super dealloc];
}

- (id)delegate {
    return delegate;
}

- (void)setDelegate:(id)value {
    delegate = value;
}



- (NSData *)peerAddress {
    return peerAddress;
}

- (HTTPServer *)server {
    return server;
}

- (HTTPServerRequest *)nextRequest {
    unsigned idx, cnt = requests ? [requests count] : 0;
    for (idx = 0; idx < cnt; idx++) {
        id obj = [requests objectAtIndex:idx];
        if ([obj response] == nil) {
            return obj;
        }
    }
    return nil;
}

- (BOOL)isValid {
    return isValid;
}

- (void)invalidate {
    if (isValid) {
        isValid = NO;
        [istream close];
        [ostream close];
        [istream release];
        [ostream release];
        istream = nil;
        ostream = nil;
        [ibuffer release];
        [obuffer release];
        ibuffer = nil;
        obuffer = nil;
        [requests release];
        requests = nil;
        [self release];
        // This last line removes the implicit retain the HTTPConnection
        // has on itself, given by the HTTPServer when it abandoned the
        // new connection.
    }
}

// YES return means that a complete request was parsed, and the caller
// should call again as the buffered bytes may have another complete
// request available.
- (BOOL)processIncomingBytes {
	
	NSLog(@"processIncomingBytes");
	
    CFHTTPMessageRef working = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);
    CFHTTPMessageAppendBytes(working, [ibuffer bytes], [ibuffer length]);
    
    // This "try and possibly succeed" approach is potentially expensive
    // (lots of bytes being copied around), but the only API available for
    // the server to use, short of doing the parsing itself.
    
    // HTTPConnection does not handle the chunked transfer encoding
    // described in the HTTP spec.  And if there is no Content-Length
    // header, then the request is the remainder of the stream bytes.
    
    if (CFHTTPMessageIsHeaderComplete(working)) {
        NSString *contentLengthValue = [(NSString *)CFHTTPMessageCopyHeaderFieldValue(working, (CFStringRef)@"Content-Length") autorelease];
        
        unsigned contentLength = contentLengthValue ? [contentLengthValue intValue] : 0;
        NSData *body = [(NSData *)CFHTTPMessageCopyBody(working) autorelease];
        unsigned bodyLength = [body length];
        if (contentLength <= bodyLength) {
            NSData *newBody = [NSData dataWithBytes:[body bytes] length:contentLength];
            [ibuffer setLength:0];
            [ibuffer appendBytes:([body bytes] + contentLength) length:(bodyLength - contentLength)];
            CFHTTPMessageSetBody(working, (CFDataRef)newBody);
        } else {
            CFRelease(working);
            return NO;
        }
    } else {
        return NO;
    }
    
    HTTPServerRequest *request = [[HTTPServerRequest alloc] initWithRequest:working connection:self];
    if (!requests) {
        requests = [[NSMutableArray alloc] init];
    }
    [requests addObject:request];
    if (delegate && [delegate respondsToSelector:@selector(HTTPConnection:didReceiveRequest:)]) {
        [delegate HTTPConnection:self didReceiveRequest:request];
    } else {
        [self performDefaultRequestHandling:request];
    }
    
    CFRelease(working);
    return YES;
}

- (void)processOutgoingBytes {
	
	
    // The HTTP headers, then the body if any, then the response stream get
    // written out, in that order.  The Content-Length: header is assumed to
    // be properly set in the response.  Outgoing responses are processed in
    // the order the requests were received (required by HTTP).
    
    // Write as many bytes as possible, from buffered bytes, response
    // headers and body, and response stream.
	
    if (![ostream hasSpaceAvailable]) {
        return;
    }
	
    unsigned olen = [obuffer length];
    if (0 < olen) {
        int writ = [ostream write:[obuffer bytes] maxLength:olen];
        // buffer any unwritten bytes for later writing
        if (writ < olen) {
            memmove([obuffer mutableBytes], [obuffer mutableBytes] + writ, olen - writ);
            [obuffer setLength:olen - writ];
            return;
        }
        [obuffer setLength:0];
    }
	
    unsigned cnt = requests ? [requests count] : 0;
    HTTPServerRequest *req = (0 < cnt) ? [requests objectAtIndex:0] : nil;
	
    CFHTTPMessageRef cfresp = req ? [req response] : NULL;
    if (!cfresp) return;
    
    if (!obuffer) {
        obuffer = [[NSMutableData alloc] init];
    }
	
    if (!firstResponseDone) {
        firstResponseDone = YES;
        NSData *serialized = [(NSData *)CFHTTPMessageCopySerializedMessage(cfresp) autorelease];
        unsigned olen = [serialized length];
        if (0 < olen) {
            int writ = [ostream write:[serialized bytes] maxLength:olen];
            if (writ < olen) {
                // buffer any unwritten bytes for later writing
                [obuffer setLength:(olen - writ)];
                memmove([obuffer mutableBytes], [serialized bytes] + writ, olen - writ);
                return;
            }
        }
    }
	
    NSInputStream *respStream = [req responseBodyStream];
    if (respStream) {
        if ([respStream streamStatus] == NSStreamStatusNotOpen) {
            [respStream open];
        }
        // read some bytes from the stream into our local buffer
        [obuffer setLength:16 * 1024];
        int read = [respStream read:[obuffer mutableBytes] maxLength:[obuffer length]];
        [obuffer setLength:read];
    }
	
    if (0 == [obuffer length]) {
        // When we get to this point with an empty buffer, then the
        // processing of the response is done. If the input stream
        // is closed or at EOF, then no more requests are coming in.
        if (delegate && [delegate respondsToSelector:@selector(HTTPConnection:didSendResponse:)]) {
            [delegate HTTPConnection:self didSendResponse:req];
        }
        [requests removeObjectAtIndex:0];
        firstResponseDone = NO;
        if ([istream streamStatus] == NSStreamStatusAtEnd && [requests count] == 0) {
            [self invalidate];
        }
        return;
    }
    
    olen = [obuffer length];
    if (0 < olen) {
        int writ = [ostream write:[obuffer bytes] maxLength:olen];
        // buffer any unwritten bytes for later writing
        if (writ < olen) {
            memmove([obuffer mutableBytes], [obuffer mutableBytes] + writ, olen - writ);
        }
        [obuffer setLength:olen - writ];
    }
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)streamEvent {
	
	
    switch(streamEvent) {
		case NSStreamEventHasBytesAvailable:;
			uint8_t buf[16 * 1024];
			uint8_t *buffer = NULL;
			unsigned long len = 0;
			if (![istream getBuffer:&buffer length:&len]) {
				int amount = [istream read:buf maxLength:sizeof(buf)];
				buffer = buf;
				len = amount;
			}
			if (0 < len) {
				if (!ibuffer) {
					ibuffer = [[NSMutableData alloc] init];
				}
				[ibuffer appendBytes:buffer length:len];
			}
			do {} while ([self processIncomingBytes]);
			break;
		case NSStreamEventHasSpaceAvailable:;
			[self processOutgoingBytes];
			break;
		case NSStreamEventEndEncountered:;
			[self processIncomingBytes];
			if (stream == ostream) {
				// When the output stream is closed, no more writing will succeed and
				// will abandon the processing of any pending requests and further
				// incoming bytes.
				[self invalidate];
			}
			break;
		case NSStreamEventErrorOccurred:;
			NSLog(@"HTTPServer stream error: %@", [stream streamError]);
			break;
		default:
			break;
    }
}


- (void)performDefaultRequestHandling:(HTTPServerRequest *)mess {
	
    CFHTTPMessageRef request = [mess request];
	
    /*    NSString *vers = [(id)CFHTTPMessageCopyVersion(request) autorelease];
     if (!vers) {
     NSLog(@"Geen vers!!");
     CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 505, NULL, (CFStringRef)vers); // Version Not Supported
     [mess setResponse:response];
     CFRelease(response);
     return;
     } */
	
    NSString *method = [(id)CFHTTPMessageCopyRequestMethod(request) autorelease];
    /*   if (!method) {
     NSLog(@"Geen method!!");
     
     CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 400, NULL, kCFHTTPVersion1_1); // Bad Request
     [mess setResponse:response];
     CFRelease(response);
     return;
     }  */
	
	NSDate *myDate = [NSDate date];
	NSString *date = [myDate descriptionWithCalendarFormat:@"%a %d %b %Y %H:%M:%S GMT" timeZone:nil locale:nil];
	
    if ([method isEqual:@"GET"]) {
        NSURL *uri = [(NSURL *)CFHTTPMessageCopyRequestURL(request) autorelease];
		NSLog(@"uri : %@",[uri path]);
        
		if ([[uri path] hasPrefix:@"/server-info"])
		{
			
			NSData *data = [[NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
                             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
                             <plist version=\"1.0\">\n\
                             <dict>\n\
                             \t<key>deviceid</key>\n\
                             \t<string>94:0C:6D:E6:80:56</string>\n\
                             \t<key>features</key>\n\
                             \t<integer>119</integer>\n\
                             \t<key>model</key>\n\
                             \t<string>AppleTV2,1</string>\n\
                             \t<key>protovers</key>\n\
                             \t<string>1.0</string>\n\
                             \t<key>srcvers</key>\n\
                             \t<string>101.28</string>\n\
                             </dict>\n\
                             </plist>\n"] dataUsingEncoding: NSASCIIStringEncoding];
            
            
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
			
			// Datum meesturen
			
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (CFStringRef)[NSString stringWithFormat:@"%@",date]);
            
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (CFStringRef)[NSString stringWithFormat:@"application/x-apple-plist+xml"]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Length", (CFStringRef)[NSString stringWithFormat:@"%ld", [data length]]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"X-Apple-Session-Id", (CFStringRef)[NSString stringWithFormat:@"00000000-0000-0000-0000-000000000000"]);
			
			
			CFHTTPMessageSetBody(response, (CFDataRef)data);
			[mess setResponse:response];
			CFRelease(response);
			
			return;
			
		}
		if ([[uri path] hasPrefix:@"/slideshow-features"])
		{
			
			
			/*<?xml version="1.0" encoding="UTF-8"?>
			 <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
			 <plist version="1.0">
			 <dict>
			 <key>themes</key>
			 <array>
			 <dict>
			 <key>key</key>
			 <string>Dissolve</string>
			 <key>name</key>
			 <string>Dissolve</string>
			 </dict>
			 <dict>
			 <key>key</key>
			 <string>Cube</string>
			 <key>name</key>
			 <string>Cube</string>
			 </dict>
			 <dict>
			 <key>key</key>
			 <string>Ripple</string>
			 <key>name</key>
			 <string>Ripple</string>
			 </dict>
			 <dict>
			 <key>key</key>
			 <string>WipeAcross</string>
			 <key>name</key>
			 <string>Wipe Across</string>
			 </dict>
			 <dict>
			 <key>key</key>
			 <string>WipeDown</string>
			 <key>name</key>
			 <string>Wipe Down</string>
			 </dict>
			 </array>
			 </dict>
			 </plist>
             */
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // Method Not Allowed
			[mess setResponse:response];
			CFRelease(response);
			
			
		}
		
		else if ([[uri path] hasPrefix:@"/playback-info"])
		{
            
			if (delegate && [delegate respondsToSelector:@selector(airplayDidAskPosition)]) {
				_playPosition =  [delegate airplayDidAskPosition];
			}
			
			if (delegate && [delegate respondsToSelector:@selector(airplayDidAskRate)]) {
				_playRate =  [delegate airplayDidAskRate];
			}
			
            
			NSNumber * duration = [NSNumber numberWithInt:100];
			
			NSString *resp = [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n \
							  <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n \
							  <plist version=\"1.0\">\n \
							  <dict>\n \
							  \t<key>duration</key>\n \
							  \t<real>%f</real>\n \
							  \t<key>position</key>\n \
							  \t<real>%f</real>\n \
							  </dict>\n \
							  </plist>",[duration floatValue],_playPosition];
			
			NSData *data = [resp dataUsingEncoding: NSASCIIStringEncoding];
			
			
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (CFStringRef)[NSString stringWithFormat:@"%@",date]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (CFStringRef)[NSString stringWithFormat:@"text/x-apple-plist+xml"]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Length", (CFStringRef)[NSString stringWithFormat:@"%ld", [data length]]);
			CFHTTPMessageSetBody(response, (CFDataRef)data);
			
			[mess setResponse:response];
			CFRelease(response);
			
			
			return;
			
			
			
		}
		
	}
	else if ([method isEqual:@"POST"])
	{
		
		NSURL *uri = [(NSURL *)CFHTTPMessageCopyRequestURL(request) autorelease];
		NSLog(@"(POST) URI : %@",uri);
		
		if ([[uri path] hasPrefix:@"/reverse"])
		{
			
            
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 101, NULL, kCFHTTPVersion1_1); // Switching Protocols
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (CFStringRef)[NSString stringWithFormat:@"%@",date]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Upgrade", (CFStringRef)[NSString stringWithFormat:@"PTTH/1.0"]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Connection", (CFStringRef)[NSString stringWithFormat:@"Upgrade"]);
			//			CFHTTPMessageSetBody(response, (CFDataRef)data);
			[mess setResponse:response];
			CFRelease(response);
			
			return;
			
		}
		else if ([[uri path] hasPrefix:@"/play"])
		{
			
			_playPosition = 0;
			NSData *Body = [(NSData *)CFHTTPMessageCopyBody(request) autorelease];
			NSString *bodyString = [[NSString alloc] initWithData:Body encoding:NSASCIIStringEncoding];
			
			NSLog(@"(POST-Play) Body : %@",bodyString);
			
			if ([bodyString hasPrefix:@"Content-Location: "])
			{
				NSString *url1 = [bodyString substringFromIndex:18];
				
				NSArray *components=[url1 componentsSeparatedByString:@"\nStart-Position: "];
				
				NSLog(@"URL : %@",[components objectAtIndex:0]);
				NSLog(@"Start : %@",[components objectAtIndex:1]);
				
				NSNumberFormatter * f = [[NSNumberFormatter alloc] init];
				[f setNumberStyle:NSNumberFormatterDecimalStyle];
				NSNumber * startposition = [f numberFromString:[components objectAtIndex:1]];
				[f release];
				
				
				if (delegate && [delegate respondsToSelector:@selector(videoSent:startPosition:)]) {
					[delegate videoSent:[[components objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]] startPosition:[startposition floatValue]];
				}
				if (delegate && [delegate respondsToSelector:@selector(videoDidPauseOrPlay:)]) {
					[delegate videoDidPauseOrPlay:FALSE];
				}
				
			}
			else {
                
				NSString *error;
				NSPropertyListFormat format;
				NSDictionary* plist = [NSPropertyListSerialization propertyListFromData:Body mutabilityOption:NSPropertyListImmutable format:&format errorDescription:&error];
				if(!plist){
					NSLog(@"Error: %@",error);
					[error release];
				}
				else {
					if (delegate && [delegate respondsToSelector:@selector(videoSent:startPosition:)]) {
						[delegate videoSent:[[plist objectForKey:@"Content-Location"] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]] startPosition:[[plist objectForKey:@"Start-Position"] floatValue]];
					}
					
				}
                
				
			}
            
            
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 101, NULL, kCFHTTPVersion1_1); // Switching Protocols
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (CFStringRef)[NSString stringWithFormat:@"text/x-apple-plist+xml"]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (CFStringRef)date);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Upgrade", (CFStringRef)[NSString stringWithFormat:@"PTTH/1.0"]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Connection", (CFStringRef)[NSString stringWithFormat:@"Upgrade"]);
			//			CFHTTPMessageSetBody(response, (CFDataRef)data);
			[mess setResponse:response];
			CFRelease(response);
			
			return;
			
		}
		else if ([[uri path] hasPrefix:@"/stop"])
		{
			
			
			
			if (delegate && [delegate respondsToSelector:@selector(videoClosed)]) {
				[delegate videoClosed];
			}
			
			
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
			[mess setResponse:response];
			CFRelease(response);
			
			return;
			
		}
		
		else if ([[uri path] hasPrefix:@"/rate?value="])
		{
			
			if ([[uri path] hasPrefix:@"/rate?value=1"])
			{
				if (delegate && [delegate respondsToSelector:@selector(videoDidPauseOrPlay:)]) {
					[delegate videoDidPauseOrPlay:FALSE];
				}
			}
			else {
				if (delegate && [delegate respondsToSelector:@selector(videoDidPauseOrPlay:)]) {
					[delegate videoDidPauseOrPlay:TRUE];
				}
			}
			
			
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 101, NULL, kCFHTTPVersion1_1); // Switching Protocols
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (CFStringRef)[NSString stringWithFormat:@"text/x-apple-plist+xml"]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (CFStringRef)date);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Upgrade", (CFStringRef)[NSString stringWithFormat:@"PTTH/1.0"]);
			CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Connection", (CFStringRef)[NSString stringWithFormat:@"Upgrade"]);
			//			CFHTTPMessageSetBody(response, (CFDataRef)data);
			[mess setResponse:response];
			CFRelease(response);
			return;
			
		}
		else if ([[uri path] hasPrefix:@"/scrub?position="])
		{
			
			
			NSString *seconds = [[uri absoluteString] substringFromIndex:16];
			
			NSNumberFormatter * f = [[NSNumberFormatter alloc] init];
			[f setNumberStyle:NSNumberFormatterDecimalStyle];
			NSNumber * position = [f numberFromString:seconds];
			[f release];
			
			_playPosition = [position intValue]/1000000;
			
			if (delegate && [delegate respondsToSelector:@selector(videoDidScrubTo:)]) {
				[delegate videoDidScrubTo:[position floatValue]];
			}
			
			
			CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
			[mess setResponse:response];
			CFRelease(response);
			return;
			
		}
		
	} // Einde POST
	else if ([method isEqual:@"PUT"])
	{
		
		NSURL *uri = [(NSURL *)CFHTTPMessageCopyRequestURL(request) autorelease];
		NSLog(@"(PUT) URI : %@",uri);

		if ([[uri path] hasPrefix:@"/photo"])
		{
			
			NSData *Body = [(NSData *)CFHTTPMessageCopyBody(request) autorelease];
			
			if (delegate && [delegate respondsToSelector:@selector(photoSent:)]) {
				[delegate photoSent:Body];
			}
			
		} else if ([[uri path] hasPrefix:@"/slideshows"]) {
			NSData *Body = [(NSData *)CFHTTPMessageCopyBody(request) autorelease];
			NSString *bodyString = [[NSString alloc] initWithData:Body encoding:NSASCIIStringEncoding];
			NSString *Response = [(NSString *)CFHTTPMessageCopyAllHeaderFields(request) autorelease];
			NSLog(@"Headers : %@",Response);
			NSLog(@"Content : %@",bodyString);
			
			NSLog(@"We kunnen helaas nog geen slideshows afspelen, dus laten we code gewoon doorgaan zo.");
		}
    }
	
	NSLog(@"Just ok if we don't know :)");
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
	[mess setResponse:response];
	CFRelease(response);
}

@end
