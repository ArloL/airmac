#import <Foundation/Foundation.h>

#import "HTTPServerRequest.h"
#import "HTTPServer.h"

// This class represents each incoming client connection.
@interface HTTPConnection : NSObject <NSStreamDelegate> {
@private
    id delegate;
    NSData *peerAddress;
    HTTPServer *server;
    NSMutableArray *requests;
    NSInputStream *istream;
    NSOutputStream *ostream;
    NSMutableData *ibuffer;
    NSMutableData *obuffer;
    BOOL isValid;
    BOOL firstResponseDone;
	float _playPosition;
	float _playRate;
	
	BOOL hasReversed;
}

@property (nonatomic, assign) id <AirplayDelegate> airplaydelegate;

- (id)initWithPeerAddress:(NSData *)addr inputStream:(NSInputStream *)istr outputStream:(NSOutputStream *)ostr forServer:(HTTPServer *)serv;

- (id)delegate;
- (void)setDelegate:(id)value;


- (NSData *)peerAddress;

- (HTTPServer *)server;

- (HTTPServerRequest *)nextRequest;
// get the next request that needs to be responded to

- (BOOL)isValid;
- (void)invalidate;
// shut down the connection

- (void)performDefaultRequestHandling:(HTTPServerRequest *)sreq;
// perform the default handling action: GET and HEAD requests for files
// in the local file system (relative to the documentRoot of the server)

- (void)processOutgoingBytes;

@end

@interface HTTPConnection (HTTPConnectionDelegateMethods)
- (void)HTTPConnection:(HTTPConnection *)conn didReceiveRequest:(HTTPServerRequest *)mess;
- (void)HTTPConnection:(HTTPConnection *)conn didSendResponse:(HTTPServerRequest *)mess;

- (void)videoSent:(NSString*)url startPosition:(float)start;
- (void)videoClosed;
- (void)videoDidPauseOrPlay:(BOOL)pause;
- (void)videoDidScrubTo:(float)seconds;
- (void)photoSent:(NSData*)photoData;

- (float)airplayDidAskPosition;
- (float)airplayDidAskRate;

// The "didReceiveRequest:" is the most interesting --
// tells the delegate when a new request comes in.
@end
