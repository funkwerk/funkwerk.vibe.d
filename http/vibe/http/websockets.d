/**
	Implements WebSocket support and fallbacks for older browsers.

	Standards: $(LINK2 https://tools.ietf.org/html/rfc6455, RFC6455)
	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Jan Krüger
*/
module vibe.http.websockets;

///
@safe unittest {
	void handleConn(scope WebSocket sock)
	{
		// simple echo server
		while (sock.connected) {
			auto msg = sock.receiveText();
			sock.send(msg);
		}
	}

	void startServer()
	{
		import vibe.http.router;
		auto router = new URLRouter;
		router.get("/ws", handleWebSockets(&handleConn));

		// Start HTTP server using listenHTTP()...
	}
}

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import vibe.core.sync;
import vibe.stream.operations;
import vibe.http.server;
import vibe.http.client;
import vibe.core.connectionpool;
import vibe.utils.array;

import core.time;
import std.array;
import std.base64;
import std.conv;
import std.exception;
import std.bitmanip;
import std.digest.sha;
import std.string;
import std.functional;
import std.uuid;
import std.base64;
import std.digest.sha;
import vibe.crypto.cryptorand;

@safe:


alias WebSocketHandshakeDelegate = void delegate(scope WebSocket);


/// Exception thrown by $(D vibe.http.websockets).
class WebSocketException: Exception
{
	@safe pure nothrow:

	///
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(msg, file, line, next);
	}

	///
	this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, next, file, line);
	}
}

/**
	Returns a WebSocket client object that is connected to the specified host.
*/
WebSocket connectWebSocket(URL url, const(HTTPClientSettings) settings = defaultSettings)
@safe {
	import std.typecons : Tuple, tuple;

	auto host = url.host;
	auto port = url.port;
	bool use_tls = (url.schema == "wss") ? true : false;

	if (port == 0)
		port = (use_tls) ? 443 : 80;

	static struct ConnInfo { string host; ushort port; bool useTLS; string proxyIP; ushort proxyPort; }
	static vibe.utils.array.FixedRingBuffer!(Tuple!(ConnInfo, ConnectionPool!HTTPClient), 16) s_connections;
	auto   ckey = ConnInfo(host, port, use_tls, settings ? settings.proxyURL.host : null, settings ? settings.proxyURL.port : 0);

	ConnectionPool!HTTPClient pool;
	foreach (c; s_connections)
		if (c[0].host == host && c[0].port == port && c[0].useTLS == use_tls && (settings is null || (c[0].proxyIP == settings.proxyURL.host && c[0].proxyPort == settings.proxyURL.port)))
			pool = c[1];

	if (!pool)
	{
		logDebug("Create HTTP client pool %s:%s %s proxy %s:%d", host, port, use_tls, (settings) ? settings.proxyURL.host : string.init, (settings) ? settings.proxyURL.port : 0);
		pool = new ConnectionPool!HTTPClient({
			auto ret = new HTTPClient;
			ret.connect(host, port, use_tls, settings);
			return ret;
		});
		if (s_connections.full)
			s_connections.popFront();
		s_connections.put(tuple(ckey, pool));
	}

	auto rng = secureRNG();
	auto challengeKey = generateChallengeKey(rng);
	auto answerKey = computeAcceptKey(challengeKey);
	auto cl = pool.lockConnection();
	auto res = cl.request((scope req){
		req.requestURL = (url.localURI == "") ? "/" : url.localURI;
		req.method = HTTPMethod.GET;
		req.headers["Upgrade"] = "websocket";
		req.headers["Connection"] = "Upgrade";
		req.headers["Sec-WebSocket-Version"] = "13";
		req.headers["Sec-WebSocket-Key"] = challengeKey;
	});

	enforce(res.statusCode == HTTPStatus.switchingProtocols, "Server didn't accept the protocol upgrade request.");

	auto key = "sec-websocket-accept" in res.headers;
	enforce(key !is null, "Response is missing the Sec-WebSocket-Accept header.");
	enforce(*key == answerKey, "Response has wrong accept key");
	auto conn = res.switchProtocol("websocket");
	auto ws = new WebSocket(conn, null, rng);
	return ws;
}

/// ditto
void connectWebSocket(URL url, scope WebSocketHandshakeDelegate del, const(HTTPClientSettings) settings = defaultSettings)
@safe {
	bool use_tls = (url.schema == "wss") ? true : false;
	url.schema = use_tls ? "https" : "http";

	/*scope*/auto rng = secureRNG();
	auto challengeKey = generateChallengeKey(rng);
	auto answerKey = computeAcceptKey(challengeKey);

	requestHTTP(url,
		(scope req) {
			req.method = HTTPMethod.GET;
			req.headers["Upgrade"] = "websocket";
			req.headers["Connection"] = "Upgrade";
			req.headers["Sec-WebSocket-Version"] = "13";
			req.headers["Sec-WebSocket-Key"] = challengeKey;
		},
		(scope res) {
			enforce(res.statusCode == HTTPStatus.switchingProtocols, "Server didn't accept the protocol upgrade request.");
			auto key = "sec-websocket-accept" in res.headers;
			enforce(key !is null, "Response is missing the Sec-WebSocket-Accept header.");
			enforce(*key == answerKey, "Response has wrong accept key");
			res.switchProtocol("websocket", (scope conn) @trusted {
				scope ws = new WebSocket(conn, null, rng);
				del(ws);
			});
		}
	);
}
/// Scheduled for deprecation - use a `@safe` callback instead.
void connectWebSocket(URL url, scope void delegate(scope WebSocket) @system del, const(HTTPClientSettings) settings = defaultSettings)
@system {
	connectWebSocket(url, (scope ws) @trusted => del(ws), settings);
}


/**
	Establishes a web socket conection and passes it to the $(D on_handshake) delegate.
*/
void handleWebSocket(scope WebSocketHandshakeDelegate on_handshake, scope HTTPServerRequest req, scope HTTPServerResponse res)
@safe {
	auto pUpgrade = "Upgrade" in req.headers;
	auto pConnection = "Connection" in req.headers;
	auto pKey = "Sec-WebSocket-Key" in req.headers;
	//auto pProtocol = "Sec-WebSocket-Protocol" in req.headers;
	auto pVersion = "Sec-WebSocket-Version" in req.headers;

	auto isUpgrade = false;

	if( pConnection ) {
		auto connectionTypes = split(*pConnection, ",");
		foreach( t ; connectionTypes ) {
			if( t.strip().toLower() == "upgrade" ) {
				isUpgrade = true;
				break;
			}
		}
	}

	string req_error;
	if (!isUpgrade) req_error = "WebSocket endpoint only accepts \"Connection: upgrade\" requests.";
	else if (!pUpgrade || icmp(*pUpgrade, "websocket") != 0) req_error = "WebSocket endpoint requires \"Upgrade: websocket\" header.";
	else if (!pVersion || *pVersion != "13") req_error = "Only version 13 of the WebSocket protocol is supported.";
	else if (!pKey) req_error = "Missing \"Sec-WebSocket-Key\" header.";

	if (req_error.length) {
		logDebug("Browser sent invalid WebSocket request: %s", req_error);
		res.statusCode = HTTPStatus.badRequest;
		res.writeBody(req_error);
		return;
	}

	auto accept = () @trusted { return cast(string)Base64.encode(sha1Of(*pKey ~ s_webSocketGuid)); } ();
	res.headers["Sec-WebSocket-Accept"] = accept;
	res.headers["Connection"] = "Upgrade";
	ConnectionStream conn = res.switchProtocol("websocket");

	WebSocket socket = new WebSocket(conn, req, null);
	try {
		on_handshake(socket);
	} catch (Exception e) {
		logDiagnostic("WebSocket handler failed: %s", e.msg);
	}
	socket.close();
}
/// Scheduled for deprecation - use a `@safe` callback instead.
void handleWebSocket(scope void delegate(scope WebSocket) @system on_handshake, scope HTTPServerRequest req, scope HTTPServerResponse res)
@system {
	handleWebSocket((scope ws) @trusted => on_handshake(ws), req, res);
}


/**
	Returns a HTTP request handler that establishes web socket conections.
*/
HTTPServerRequestDelegateS handleWebSockets(void function(scope WebSocket) @safe on_handshake)
@safe {
	return handleWebSockets(() @trusted { return toDelegate(on_handshake); } ());
}
/// ditto
HTTPServerRequestDelegateS handleWebSockets(WebSocketHandshakeDelegate on_handshake)
@safe {
	void callback(scope HTTPServerRequest req, scope HTTPServerResponse res)
	@safe {
		auto pUpgrade = "Upgrade" in req.headers;
		auto pConnection = "Connection" in req.headers;
		auto pKey = "Sec-WebSocket-Key" in req.headers;
		//auto pProtocol = "Sec-WebSocket-Protocol" in req.headers;
		auto pVersion = "Sec-WebSocket-Version" in req.headers;

		auto isUpgrade = false;

		if( pConnection ) {
			auto connectionTypes = split(*pConnection, ",");
			foreach( t ; connectionTypes ) {
				if( t.strip().toLower() == "upgrade" ) {
					isUpgrade = true;
					break;
				}
			}
		}
		if( !(isUpgrade &&
			  pUpgrade && icmp(*pUpgrade, "websocket") == 0 &&
			  pKey &&
			  pVersion && *pVersion == "13") )
		{
			logDebug("Browser sent invalid WebSocket request.");
			res.statusCode = HTTPStatus.badRequest;
			res.writeVoidBody();
			return;
		}

		auto accept = () @trusted { return cast(string)Base64.encode(sha1Of(*pKey ~ s_webSocketGuid)); } ();
		res.headers["Sec-WebSocket-Accept"] = accept;
		res.headers["Connection"] = "Upgrade";
		res.switchProtocol("websocket", (scope conn) {
			// TODO: put back 'scope' once it is actually enforced by DMD
			/*scope*/ auto socket = new WebSocket(conn, req, null);
			try on_handshake(socket);
			catch (Exception e) {
				logDiagnostic("WebSocket handler failed: %s", e.msg);
			}
			socket.close();
		});
	}
	return &callback;
}
/// Scheduled for deprecation - use a `@safe` callback instead.
HTTPServerRequestDelegateS handleWebSockets(void delegate(scope WebSocket) @system on_handshake)
@system {
	return handleWebSockets(delegate (scope ws) @trusted => on_handshake(ws));
}
/// Scheduled for deprecation - use a `@safe` callback instead.
HTTPServerRequestDelegateS handleWebSockets(void function(scope WebSocket) @system on_handshake)
@system {
	return handleWebSockets(delegate (scope ws) @trusted => on_handshake(ws));
}


/**
 * Represents a single _WebSocket connection.
 *
 * ---
 * shared static this ()
 * {
 *   runTask(() => connectToWS());
 * }
 *
 * void connectToWS ()
 * {
 *   auto ws_url = URL("wss://websockets.example.com/websocket/auth_token");
 *   auto ws = connectWebSocket(ws_url);
 *   logInfo("WebSocket connected");
 *
 *   while (ws.waitForData())
 *   {
 *     auto txt = ws.receiveText;
 *     logInfo("Received: %s", txt);
 *   }
 *   logFatal("Connection lost!");
 * }
 * ---
 */
final class WebSocket {
@safe:

	private {
		ConnectionStream m_conn;
		bool m_sentCloseFrame = false;
		IncomingWebSocketMessage m_nextMessage = null;
		const HTTPServerRequest m_request;
		Task m_reader;
		InterruptibleTaskMutex m_readMutex, m_writeMutex;
		InterruptibleTaskCondition m_readCondition;
		Timer m_pingTimer;
		uint m_lastPingIndex;
		bool m_pongReceived;
		bool m_pongSkipped;
		short m_closeCode;
		const(char)[] m_closeReason;
		/// The entropy generator to use
		/// If not null, it means this is a server socket.
		RandomNumberStream m_rng;
	}

	/**
	 * Private constructor, called from `connectWebSocket`.
	 *
	 * Params:
	 *	 conn = Underlying connection string
	 *	 request = HTTP request used to establish the connection
	 *	 rng = Source of entropy to use.  If null, assume we're a server socket
	 */
	private this(ConnectionStream conn, in HTTPServerRequest request,
				 RandomNumberStream rng)
	{
		m_conn = conn;
		m_request = request;
		assert(m_conn);
		m_rng = rng;
		m_writeMutex = new InterruptibleTaskMutex;
		m_readMutex = new InterruptibleTaskMutex;
		m_readCondition = new InterruptibleTaskCondition(m_readMutex);
		m_readMutex.performLocked!({
			m_reader = runTask(&startReader);
			if (request !is null && request.serverSettings.webSocketPingInterval != Duration.zero) {
				m_pongReceived = true;
				m_pingTimer = setTimer(request.serverSettings.webSocketPingInterval, &sendPing, true);
			}
		});
	}

	/**
		Determines if the WebSocket connection is still alive and ready for sending.

		Note that for determining the ready state for $(EM reading), you need
		to use $(D waitForData) instead, because both methods can return
		different values while a disconnect is in proress.

		See_also: $(D waitForData)
	*/
	@property bool connected() { return m_conn.connected && !m_sentCloseFrame; }

	/**
		Returns the close code sent by the remote end.

		Note if the connection was never opened, is still alive, or was closed
		locally this value will be 0. If no close code was given by the remote
		end in the close frame, the value will be 1005. If the connection was
		not closed cleanly by the remote end, this value will be 1006.
	*/
	@property short closeCode() { return m_closeCode; }

	/**
		Returns the close reason sent by the remote end.

		Note if the connection was never opened, is still alive, or was closed
		locally this value will be an empty string.
	*/
	@property const(char)[] closeReason() { return m_closeReason; }

	/**
		The HTTP request that established the web socket connection.
	*/
	@property const(HTTPServerRequest) request() const { return m_request; }

	/**
		Checks if data is readily available for read.
	*/
	@property bool dataAvailableForRead() { return m_conn.dataAvailableForRead || m_nextMessage !is null; }

	/** Waits until either a message arrives or until the connection is closed.

		This function can be used in a read loop to cleanly determine when to stop reading.
	*/
	bool waitForData()
	{
		if (m_nextMessage) return true;

		m_readMutex.performLocked!({
			while (connected && m_nextMessage is null)
				m_readCondition.wait();
		});
		return m_nextMessage !is null;
	}

	/// ditto
	bool waitForData(Duration timeout)
	{
		import std.datetime;

		if (m_nextMessage) return true;

		immutable limit_time = Clock.currTime(UTC()) + timeout;

		m_readMutex.performLocked!({
			while (connected && m_nextMessage is null && timeout > 0.seconds) {
				m_readCondition.wait(timeout);
				timeout = limit_time - Clock.currTime(UTC());
			}
		});
		return m_nextMessage !is null;
	}

	/**
		Sends a text message.

		On the JavaScript side, the text will be available as message.data (type string).

		Throws:
			A `WebSocketException` is thrown if the connection gets closed
			before or during the transfer of the message.
	*/
	void send(scope const(char)[] data)
	{
		send(
			(scope message) { message.write(cast(const ubyte[])data); },
			FrameOpcode.text);
	}

	/**
		Sends a binary message.

		On the JavaScript side, the text will be available as message.data (type Blob).

		Throws:
			A `WebSocketException` is thrown if the connection gets closed
			before or during the transfer of the message.
	*/
	void send(in ubyte[] data)
	{
		send((scope message){ message.write(data); }, FrameOpcode.binary);
	}

	/**
		Sends a message using an output stream.

		Throws:
			A `WebSocketException` is thrown if the connection gets closed
			before or during the transfer of the message.
	*/
	void send(scope void delegate(scope OutgoingWebSocketMessage) @safe sender, FrameOpcode frameOpcode)
	{
		m_writeMutex.performLocked!({
			enforceEx!WebSocketException(!m_sentCloseFrame, "WebSocket connection already actively closed.");
			/*scope*/auto message = new OutgoingWebSocketMessage(m_conn, frameOpcode, m_rng);
			scope(exit) message.finalize();
			sender(message);
		});
	}

	/// Compatibility overload - will be removed soon.
	deprecated("Call the overload which requires an explicit FrameOpcode.")
	void send(scope void delegate(scope OutgoingWebSocketMessage) @safe sender)
	{
		send(sender, FrameOpcode.text);
	}

	/**
		Actively closes the connection.

		Params:
			code = Numeric code indicating a termination reason.
			reason = Message describing why the connection was terminated.
	*/
	void close(short code = 0, scope const(char)[] reason = "")
	{
		//control frame payloads are limited to 125 bytes
		assert(reason.length <= 123);

		if (connected) {
			m_writeMutex.performLocked!({
				m_sentCloseFrame = true;
				Frame frame;
				frame.opcode = FrameOpcode.close;
				if(code != 0)
					frame.payload = std.bitmanip.nativeToBigEndian(code) ~ cast(const ubyte[])reason;
				frame.fin = true;
				frame.writeFrame(m_conn, m_rng);
			});
		}
		if (m_pingTimer) m_pingTimer.stop();
		if (Task.getThis() != m_reader) m_reader.join();
	}

	/**
		Receives a new message and returns its contents as a newly allocated data array.

		Params:
			strict = If set, ensures the exact frame type (text/binary) is received and throws an execption otherwise.
		Throws: WebSocketException if the connection is closed or
			if $(D strict == true) and the frame received is not the right type
	*/
	ubyte[] receiveBinary(bool strict = true)
	{
		ubyte[] ret;
		receive((scope message){
			enforceEx!WebSocketException(!strict || message.frameOpcode == FrameOpcode.binary,
				"Expected a binary message, got "~message.frameOpcode.to!string());
			ret = message.readAll();
		});
		return ret;
	}
	/// ditto
	string receiveText(bool strict = true)
	{
		string ret;
		receive((scope message){
			enforceEx!WebSocketException(!strict || message.frameOpcode == FrameOpcode.text,
				"Expected a text message, got "~message.frameOpcode.to!string());
			ret = message.readAllUTF8();
		});
		return ret;
	}

	/**
		Receives a new message using an InputStream.
		Throws: WebSocketException if the connection is closed.
	*/
	void receive(scope void delegate(scope IncomingWebSocketMessage) @safe receiver)
	{
		m_readMutex.performLocked!({
			while (!m_nextMessage) {
				enforceEx!WebSocketException(connected, "Connection closed while reading message.");
				m_readCondition.wait();
			}
			receiver(m_nextMessage);
			m_nextMessage = null;
			m_readCondition.notifyAll();
		});
	}

	private void startReader()
	{
		m_readMutex.performLocked!({}); //Wait until initialization
		scope (exit) m_readCondition.notifyAll();
		try {
			while (!m_conn.empty) {
				assert(!m_nextMessage);
				if (m_pingTimer) {
					if (m_pongSkipped) {
						logDebug("Pong not received, closing connection");
						m_writeMutex.performLocked!({
							m_conn.close();
						});
						return;
					}
					if (!m_conn.waitForData(request.serverSettings.webSocketPingInterval))
						continue;
				}
				/*scope*/auto msg = new IncomingWebSocketMessage(m_conn, m_rng);
				if (msg.frameOpcode == FrameOpcode.pong) {
					enforce(msg.peek().length == uint.sizeof, "Pong payload has wrong length");
					enforce(m_lastPingIndex == littleEndianToNative!uint(msg.peek()[0..uint.sizeof]), "Pong payload has wrong value");
					m_pongReceived = true;
					continue;
				}
				if(msg.frameOpcode == FrameOpcode.close) {
					logDebug("Got closing frame (%s)", m_sentCloseFrame);

					// If no close code was passed, we default to 1005
					this.m_closeCode = 1005;

					// If provided in the frame, attempt to parse the close code/reason
					if (msg.peek().length >= short.sizeof) {
						this.m_closeCode = bigEndianToNative!short(msg.peek()[0..short.sizeof]);

						if (msg.peek().length > short.sizeof) {
							this.m_closeReason = cast(const(char) [])msg.peek()[short.sizeof..$];
						}
					}

					if(!m_sentCloseFrame) close();
					logDebug("Terminating connection (%s)", m_sentCloseFrame);
					m_conn.close();
					return;
				}
				m_readMutex.performLocked!({
					m_nextMessage = msg;
					m_readCondition.notifyAll();
					while (m_nextMessage) m_readCondition.wait();
				});
			}
		} catch (Exception e) {
			logDiagnostic("Error while reading websocket message: %s", e.msg);
			logDiagnostic("Closing connection.");
		}

		// If no close code was passed, e.g. this was an unclean termination
		//  of our websocket connection, set the close code to 1006.
		if (this.m_closeCode == 0) this.m_closeCode = 1006;
		m_conn.close();
	}

	private void sendPing()
	nothrow {
		if (!m_pongReceived) {
			logDebug("Pong skipped");
			m_pongSkipped = true;
			m_pingTimer.stop();
			return;
		}
		try m_writeMutex.performLocked!({
			m_pongReceived = false;
			Frame ping;
			ping.opcode = FrameOpcode.ping;
			ping.fin = true;
			ping.payload = nativeToLittleEndian(++m_lastPingIndex);
			ping.writeFrame(m_conn, m_rng);
			logDebug("Ping sent");
		});
		catch (Exception e) {
			logError("Failed to acquire write mutex for sending a WebSocket ping frame: %s", e.msg);
		}
	}
}

/**
	Represents a single outgoing _WebSocket message as an OutputStream.
*/
final class OutgoingWebSocketMessage : OutputStream {
@safe:
	private {
		RandomNumberStream m_rng;
		Stream m_conn;
		FrameOpcode m_frameOpcode;
		Appender!(ubyte[]) m_buffer;
		bool m_finalized = false;
	}

	this(Stream conn, FrameOpcode frameOpcode, RandomNumberStream rng)
	{
		assert(conn !is null);
		m_conn = conn;
		m_frameOpcode = frameOpcode;
		m_rng = rng;
	}

	size_t write(in ubyte[] bytes, IOMode mode)
	{
		assert(!m_finalized);

		if (!m_buffer.data.length) {
			ubyte[Frame.maxHeaderSize] header_padding;
			m_buffer.put(header_padding[]);
		}

		m_buffer.put(bytes);
		return bytes.length;
	}

	void flush()
	{
		assert(!m_finalized);
		if (m_buffer.data.length > 0)
			sendFrame(false);
	}

	void finalize()
	{
		if (m_finalized) return;
		m_finalized = true;
		sendFrame(true);
	}

	private void sendFrame(bool fin)
	{
		if (!m_buffer.data.length)
			write(null, IOMode.once);

		assert(m_buffer.data.length >= Frame.maxHeaderSize);

		Frame frame;
		frame.fin = fin;
		frame.opcode = m_frameOpcode;
		frame.payload = m_buffer.data[Frame.maxHeaderSize .. $];
		auto hsize = frame.getHeaderSize(m_rng !is null);
		auto msg = m_buffer.data[Frame.maxHeaderSize-hsize .. $];
		frame.writeHeader(msg[0 .. hsize], m_rng);
		m_conn.write(msg);
		m_conn.flush();
		m_buffer.clear();
	}

	alias write = OutputStream.write;
}


/**
	Represents a single incoming _WebSocket message as an InputStream.
*/
final class IncomingWebSocketMessage : InputStream {
@safe:
	private {
		RandomNumberStream m_rng;
		Stream m_conn;
		Frame m_currentFrame;
	}

	this(Stream conn, RandomNumberStream rng)
	{
		assert(conn !is null);
		m_conn = conn;
		m_rng = rng;
		readFrame();
	}

	@property bool empty() const { return m_currentFrame.payload.length == 0; }

	@property ulong leastSize() const { return m_currentFrame.payload.length; }

	@property bool dataAvailableForRead() { return true; }

	/// The frame type for this nessage;
	@property FrameOpcode frameOpcode() const { return m_currentFrame.opcode; }

	const(ubyte)[] peek() { return m_currentFrame.payload; }

	/**
	 * Retrieve the next websocket frame of the stream and discard the current
	 * one
	 *
	 * This function is helpful if one wish to process frames by frames,
	 * or minimize memory allocation, as `peek` will only return the current
	 * frame data, and read requires a pre-allocated buffer.
	 *
	 * Returns:
	 * `false` if the current frame is the final one, `true` if a new frame
	 * was read.
	 */
	bool skipFrame()
	{
		if (m_currentFrame.fin)
			return false;

		m_currentFrame = Frame.readFrame(m_conn);
		return true;
	}

	size_t read(scope ubyte[] dst, IOMode mode)
	{
		size_t nread = 0;

		while (dst.length > 0) {
			enforceEx!WebSocketException(!empty , "cannot read from empty stream");
			enforceEx!WebSocketException(leastSize > 0, "no data available" );

			import std.algorithm : min;
			auto sz = cast(size_t)min(leastSize, dst.length);
			dst[0 .. sz] = m_currentFrame.payload[0 .. sz];
			dst = dst[sz .. $];
			m_currentFrame.payload = m_currentFrame.payload[sz .. $];
			nread += sz;

			if (leastSize == 0) {
				if (mode == IOMode.immediate || mode == IOMode.once && nread > 0)
					break;
				this.skipFrame();
			}
		}

		return nread;
	}

	alias read = InputStream.read;

	private void readFrame() {
		Frame frame;
		do {
			frame = Frame.readFrame(m_conn);
			switch(frame.opcode) {
				case FrameOpcode.continuation:
				case FrameOpcode.text:
				case FrameOpcode.binary:
				case FrameOpcode.close:
				case FrameOpcode.pong:
					m_currentFrame = frame;
					break;
				case FrameOpcode.ping:
					Frame pong;
					pong.opcode = FrameOpcode.pong;
					pong.fin = true;
					pong.payload = frame.payload;

					pong.writeFrame(m_conn, m_rng);
					break;
				default:
					throw new WebSocketException("unknown frame opcode");
			}
		} while( frame.opcode == FrameOpcode.ping );
	}
}

/// Magic string defined by the RFC for challenging the server during upgrade
private static immutable s_webSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";


/**
 * The Opcode is 4 bits, as defined in Section 5.2
 *
 * Values are defined in section 11.8
 * Currently only 6 values are defined, however the opcode is defined as
 * taking 4 bits.
 */
private enum FrameOpcode : ubyte {
	continuation = 0x0,
	text = 0x1,
	binary = 0x2,
	close = 0x8,
	ping = 0x9,
	pong = 0xA
}
static assert(FrameOpcode.max < 0b1111, "FrameOpcode is only 4 bits");


private struct Frame {
@safe:
	enum maxHeaderSize = 14;

	bool fin;
	FrameOpcode opcode;
	ubyte[] payload;

    /**
     * Return the header length encoded with the expected amount of bits
     *
     * The WebSocket RFC define a variable-length payload length.
     * In short, it means that:
     * - If the length is <= 125, it is stored as the 7 least significant
     *   bits of the second header byte.  The first bit is reserved for MASK.
     * - If the length is <= 65_536 (so it fits in 2 bytes), a magic value of
     *   126 is stored in the aforementioned 7 bits, and the actual length
     *   is stored in the next two bytes, resulting in a 4 bytes header
     *   ( + masking key, if any).
     * - If the length is > 65_536, a magic value of 127 will be used for
     *   the 7-bit field, and the next 8 bytes are expected to be the length,
     *   resulting in a 10 bytes header ( + masking key, if any).
     *
     * Those functions encapsulate all this logic and allow to just get the
     * length with the desired size.
     *
     * Return:
     * - For `ubyte`, the value to store in the 7 bits field, either the
     *   length or a magic value (126 or 127).
     * - For `ushort`, a value in the range [126; 65_536].
     *   If payload.length is not in this bound, an assertion will be triggered.
     * - For `ulong`, a value in the range [65_537; size_t.max].
     *   If payload.length is not in this bound, an assertion will be triggered.
     */
	size_t getHeaderSize(bool mask)
	{
		size_t ret = 1;
		if (payload.length < 126) ret += 1;
		else if (payload.length < 65536) ret += 3;
		else ret += 9;
		if (mask) ret += 4;
		return ret;
	}

	void writeHeader(ubyte[] dst, RandomNumberStream sys_rng)
	{
		ubyte[4] buff;
		ubyte firstByte = cast(ubyte)opcode;
		if (fin) firstByte |= 0x80;
		dst[0] = firstByte;
		dst = dst[1 .. $];

		auto b1 = sys_rng ? 0x80 : 0x00;

		if (payload.length < 126) {
			dst[0] = cast(ubyte)(b1 | payload.length);
			dst = dst[1 .. $];
		} else if (payload.length < 65536) {
			dst[0] = cast(ubyte) (b1 | 126);
			dst[1 .. 3] = std.bitmanip.nativeToBigEndian(cast(ushort)payload.length);
			dst = dst[3 .. $];
		} else {
			dst[0] = cast(ubyte) (b1 | 127);
			dst[1 .. 9] = std.bitmanip.nativeToBigEndian(cast(ulong)payload.length);
			dst = dst[9 .. $];
		}

		if (sys_rng) {
            sys_rng.read(dst[0 .. 4]);
			for (size_t i = 0; i < payload.length; i++)
				payload[i] ^= dst[i % 4];
		}
	}

	void writeFrame(OutputStream stream, RandomNumberStream sys_rng)
	{
		import vibe.stream.wrapper;

		auto rng = StreamOutputRange(stream);
		ubyte[maxHeaderSize] hdr;
		writeHeader(hdr[], sys_rng);
		rng.put(hdr[0 .. getHeaderSize(sys_rng !is null)]);
		rng.flush();
		stream.flush();
	}

	static Frame readFrame(InputStream stream)
	{
		Frame frame;
		ubyte[8] data;

		stream.read(data[0 .. 2]);
		frame.fin_rsv_opcode = data[0];

		bool masked = !!(data[1] & 0b1000_0000);

		//parsing length
		ulong length = data[1] & 0b0111_1111;
		if (length == 126) {
			stream.read(data[0 .. 2]);
			length = bigEndianToNative!ushort(data[0 .. 2]);
		} else if (length == 127) {
			stream.read(data);
			length = bigEndianToNative!ulong(data);

			// RFC 6455, 5.2, 'Payload length': If 127, the following 8 bytes
			// interpreted as a 64-bit unsigned integer (the most significant
			// bit MUST be 0)
			enforceEx!WebSocketException(!(length >> 63),
				"Received length has a non-zero most significant bit");

		}
		logDebug("Read frame: %s %s %s length=%d",
				 frame.opcode,
				 frame.fin ? "final frame" : "continuation",
				 masked ? "masked" : "not masked",
				 length);

		// Masking key is 32 bits / uint
		if (masked)
			stream.read(data[0 .. 4]);

		// Read payload
		// TODO: Provide a way to limit the size read, easy
		// DOS for server code here (rejectedsoftware/vibe.d#1496).
		enforceEx!WebSocketException(length <= size_t.max);
		frame.payload = new ubyte[](cast(size_t)length);
		stream.read(frame.payload);

		//de-masking
		if (masked)
			foreach (size_t i; 0 .. cast(size_t)length)
				frame.payload[i] = frame.payload[i] ^ data[i % 4];

		return frame;
	}
}

unittest {
	import std.algorithm.searching : all;

	final class DummyRNG : RandomNumberStream {
	@safe:
		@property bool empty() { return false; }
		@property ulong leastSize() { return ulong.max; }
		@property bool dataAvailableForRead() { return true; }
		const(ubyte)[] peek() { return null; }
		size_t read(scope ubyte[] buffer, IOMode mode) @trusted { buffer[] = 13; return buffer.length; }
		alias read = RandomNumberStream.read;
	}

	ubyte[14] hdrbuf;
	auto rng = new DummyRNG;

	Frame f;
	f.payload = new ubyte[125];

	assert(f.getHeaderSize(false) == 2);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 2], null);
	assert(hdrbuf[0 .. 2] == [0, 125]);

	assert(f.getHeaderSize(true) == 6);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 6], rng);
	assert(hdrbuf[0 .. 2] == [0, 128|125]);
	assert(hdrbuf[2 .. 6].all!(b => b == 13));

	f.payload = new ubyte[126];
	assert(f.getHeaderSize(false) == 4);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 4], null);
	assert(hdrbuf[0 .. 4] == [0, 126, 0, 126]);

	assert(f.getHeaderSize(true) == 8);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 8], rng);
	assert(hdrbuf[0 .. 4] == [0, 128|126, 0, 126]);
	assert(hdrbuf[4 .. 8].all!(b => b == 13));

	f.payload = new ubyte[65535];
	assert(f.getHeaderSize(false) == 4);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 4], null);
	assert(hdrbuf[0 .. 4] == [0, 126, 255, 255]);

	assert(f.getHeaderSize(true) == 8);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 8], rng);
	assert(hdrbuf[0 .. 4] == [0, 128|126, 255, 255]);
	assert(hdrbuf[4 .. 8].all!(b => b == 13));

	f.payload = new ubyte[65536];
	assert(f.getHeaderSize(false) == 10);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 10], null);
	assert(hdrbuf[0 .. 10] == [0, 127, 0, 0, 0, 0, 0, 1, 0, 0]);

	assert(f.getHeaderSize(true) == 14);
	hdrbuf[] = 0;
	f.writeHeader(hdrbuf[0 .. 14], rng);
	assert(hdrbuf[0 .. 10] == [0, 128|127, 0, 0, 0, 0, 0, 1, 0, 0]);
	assert(hdrbuf[10 .. 14].all!(b => b == 13));
}

/**
 * Generate a challenge key for the protocol upgrade phase.
 */
private string generateChallengeKey(scope RandomNumberStream rng)
{
	ubyte[16] buffer;
	rng.read(buffer);
	return Base64.encode(buffer);
}

private string computeAcceptKey(string challengekey)
{
	immutable(ubyte)[] b = challengekey.representation;
	immutable(ubyte)[] a = s_webSocketGuid.representation;
	SHA1 hash;
	hash.start();
	hash.put(b);
	hash.put(a);
	auto result = Base64.encode(hash.finish());
	return to!(string)(result);
}
