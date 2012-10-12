#import <Foundation/Foundation.h>

@class HTTPConnection;

// As NSURLRequest and NSURLResponse are not entirely suitable for use from
// the point of view of an HTTP server, we use CFHTTPMessageRef to encapsulate
// requests and responses.  This class packages the (future) response with a
// request and other info for convenience.
@interface HTTPServerRequest : NSObject {
@private
    HTTPConnection *connection;
    CFHTTPMessageRef request;
    CFHTTPMessageRef response;
    NSInputStream *responseStream;
}

- (id)initWithRequest:(CFHTTPMessageRef)req connection:(HTTPConnection *)conn;

- (HTTPConnection *)connection;

- (CFHTTPMessageRef)request;

- (CFHTTPMessageRef)response;
- (void)setResponse:(CFHTTPMessageRef)value;
// The response may include a body.  As soon as the response is set,
// the response may be written out to the network.

- (NSInputStream *)responseBodyStream;
- (void)setResponseBodyStream:(NSInputStream *)value;
// If there is to be a response body stream (when, say, a big
// file is to be returned, rather than reading the whole thing
// into memory), then it must be set on the request BEFORE the
// response [headers] itself.

@end
