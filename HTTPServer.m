#import "HTTPServer.h"

#import "HTTPServerRequest.h"
#import "HTTPConnection.h"

@implementation HTTPServer

- (id)init {
    connClass = [HTTPConnection self];
    return self;
}

- (void)dealloc {
    [super dealloc];
}

- (Class)connectionClass {
    return connClass;
}

- (void)setConnectionClass:(Class)value {
    connClass = value;
}


// Converts the TCPServer delegate notification into the HTTPServer delegate method.
- (void)handleNewConnectionFromAddress:(NSData *)addr inputStream:(NSInputStream *)istr outputStream:(NSOutputStream *)ostr {
    HTTPConnection *connection = [[connClass alloc] initWithPeerAddress:addr inputStream:istr outputStream:ostr forServer:self];
    [connection setDelegate:[self delegate]];
    if ([self delegate] && [[self delegate] respondsToSelector:@selector(HTTPServer:didMakeNewConnection:)]) { 
        [[self delegate] HTTPServer:self didMakeNewConnection:connection];
    }
    // The connection at this point is turned loose to exist on its
    // own, and not released or autoreleased.  Alternatively, the
    // HTTPServer could keep a list of connections, and HTTPConnection
    // would have to tell the server to delete one at invalidation
    // time.  This would perhaps be more correct and ensure no
    // spurious leaks get reported by the tools, but HTTPServer
    // has nothing further it wants to do with the HTTPConnections,
    // and would just be "owning" the connections for form.
}

- (id)airplaydelegate {
    return airplaydelegate;
}

- (void)setAirplayDelegate:(id)value {
    airplaydelegate = value;
}


@end
