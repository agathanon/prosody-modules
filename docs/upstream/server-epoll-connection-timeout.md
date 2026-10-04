# Upstream bug: net.server_epoll closes new connections whose server speaks first

**Status:** not yet reported to Prosody. Found and documented 2026-10-04.

## Summary

In Prosody 13.0's `net/server_epoll.lua`, an outgoing connection can be
closed right after its first data is delivered, with the reason
"connection timeout". This happens when the remote end sends data first
(as SMTP, POP3, IMAP and FTP servers do) and the socket becomes readable
before Prosody has marked the connection as connected. The data is passed
to the listener, and then the connection is destroyed.

XMPP and HTTP clients send first, which is probably why this hasn't been
noticed.

## Affected versions

- Found with the `prosodyim/prosody:13.0` Docker image: Prosody 13.0
  nightly build 100 (2026-09-24, cafd74b9c5ea), Lua 5.4, epoll backend.
- The same code is on both the 13.0 branch and trunk as of hg revision
  14237 (2026-09-24, "Merge 13.0->trunk").

## Cause

`interface:onreadable()` (around line 488 on the 13.0 branch):

```lua
function interface:onreadable()
	local data, err, partial = self.conn:receive(self.read_size or cfg.read_size);
	if data then
		self:onconnect();
		self:onincoming(data);
	else
		if err == "wantread" then
			...
		elseif err == "timeout" and not self._connected then
			err = "connection timeout";       -- (1)
		end
		if partial and partial ~= "" then
			self:onconnect();                 -- (2)
			self:onincoming(partial, err);
		end
		if err == "closed" and self._connected then
			...
		elseif err ~= "timeout" then
			self:debug("Read error, closing (%s)", err);
			self:on("disconnect", err);       -- (3)
			self:destroy();
			return;
		end
	end
	...
```

A non-blocking `receive()` that returns some data but not a complete
result gives `nil, "timeout", partial`: "timeout" here just means "no
more data for now". If that happens on the first read, before
`onwritable()` has called `onconnect()`:

1. `err` is relabelled "connection timeout" because `_connected` is
   still false,
2. the partial data is delivered, and `onconnect()` marks the connection
   as connected, but `err` keeps the new label,
3. so the connection is closed as if it had timed out.

With `net.connect`'s default read pattern, `"*a"`, every read before the
remote closes returns partial data, so the first read always takes this
path. With a numeric pattern it happens whenever fewer bytes than
requested are available. It depends on the remote's data arriving before
the socket's first writable event has been processed, so a fast server
on the same machine or network triggers it most.

## Reproduction

Any TCP server that sends a greeting on connect will do. This repository's
dev setup (`docker-compose.yml`) has a Mailpit SMTP server reachable from
Prosody as `mailpit:1025`.

1. `docker compose up -d`
2. Run this in `prosodyctl shell`. It's shown on several lines for
   readability, but must be entered as one line after `> `, e.g. with
   `docker compose exec prosody prosodyctl shell "> ..."`:

   ```lua
   local connect = require "prosody.net.connect".connect;
   local basic = require "prosody.net.resolvers.basic";
   prosody.repro = { greeted = 0, ok = 0, bogus = 0 };
   for _ = 1, 50 do
   	local greeted = false;
   	connect(basic.new("mailpit", 1025, "tcp"), {
   		onconnect = function () end;
   		onincoming = function (conn)
   			if not greeted then
   				greeted = true;
   				prosody.repro.greeted = prosody.repro.greeted + 1;
   				conn:write("QUIT\r\n");
   			end
   		end;
   		ondisconnect = function (_, reason)
   			if reason == "connection timeout" and greeted then
   				prosody.repro.bogus = prosody.repro.bogus + 1;
   			else
   				prosody.repro.ok = prosody.repro.ok + 1;
   			end
   		end;
   	});
   end
   return "started";
   ```

3. A few seconds later, also after `> `:

   ```lua
   return ('greeted %d; closed normally %d; closed as "connection timeout" after receiving data %d'):format(prosody.repro.greeted, prosody.repro.ok, prosody.repro.bogus)
   ```

**Result:** `greeted 50; closed normally 0; closed as "connection timeout"
after receiving data 50`. Every connection received the greeting and was
then closed by Prosody before the server could answer `QUIT`.

With debug logging, each connection shows:

```
Connected (FD 22 (172.20.0.2, 1025, 172.20.0.3, 40068))
...                                       (listener handles the greeting)
Read error, closing (connection timeout)
```

## Proposed fix

Only treat the read as a connection timeout if no data was received:

```diff
--- a/net/server_epoll.lua
+++ b/net/server_epoll.lua
@@ -498,7 +498,7 @@
 			self:set(nil, true);
 			self:setwritetimeout();
 			err = "timeout";
-		elseif err == "timeout" and not self._connected then
+		elseif err == "timeout" and not self._connected and not (partial and partial ~= "") then
 			err = "connection timeout";
 		end
 		if partial and partial ~= "" then
```

Receiving data proves the connection is up, so the relabelling can't be
right in that case; behavior without data is unchanged.

**Tested:** with this patch mounted over the image's
`/usr/share/lua/5.2/prosody/net/server_epoll.lua`, the reproduction above
gives `greeted 50; closed normally 50; closed as "connection timeout"
after receiving data 0`. Not run against Prosody's own test suite.

An alternative would be to call `onconnect()` before classifying the
error whenever data was received.

## Workaround in this repository

`mod_smtp_async` connects with the read pattern `"*l"` (commit e567b8d).
An SMTP greeting is a single line, so the first read returns it as
complete data, which takes the unaffected `if data then` branch. Before
the workaround, about half of first attempts failed in bursts of 20 emails
to a local Mailpit; after it, 100 of 100 succeeded. It doesn't cover a
greeting that arrives split across packets, which is rare; such a failure
is retried like any other temporary error.

Once Prosody is fixed, the workaround can stay: reading line by line is
harmless for SMTP.

## Reporting

Check first whether it's already known, then report it on Prosody's issue
tracker (https://issues.prosody.im/, "New issue"; needs an account) as a
Defect against the 13.0 milestone, or raise it in the Prosody chat room
(prosody@conference.prosody.im). Include the cause, the reproduction and
the proposed fix above.
