/*The MIT License (MIT)

Copyright (c) 2016 Denis Feklushkin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

/// PostgreSQL database client implementation.
// adapt from https://github.com/denizzzka/vibe.d.db.postgresql
module vibe.db.postgresql;

public import dpq2: ValueFormat;
public import dpq2.exception: Dpq2Exception;
public import dpq2.result;
public import dpq2.connection: ConnectionException, connStringCheck, ConnectionStart, CancellationException;
public import dpq2.args;
public import derelict.pq.pq;

import vibe.core.connectionpool: ConnectionPool, VibeLockedConnection = LockedConnection;
import vibe.core.log;
import core.time: Duration, dur;
import std.exception: enforce;
import std.conv: to;


/// A Postgres client with connection pooling.
class PostgresClient{
  private ConnectionPool!Connection pool;

  this(string connString,uint connNum)  {
    connString.connStringCheck;
    pool = new ConnectionPool!Connection( () @safe {
      return new Connection( connString);
    }, connNum);
  }
  /// Use connection from the pool.
  T pickConnection(T)(scope T delegate(scope LockedConnection conn) dg) {
    logDebugV( "get connection from the pool");
    scope conn = pool.lockConnection();

    try
    return dg( conn);
    catch(ConnectionException e) {
      conn.reset(); // also may throw ConnectionException and this is normal behaviour
      throw e;
    }
  }
}

alias Connection = Dpq2Connection;
alias LockedConnection = VibeLockedConnection!Connection;

/**
 * dpq2.Connection adopted for using with Vibe.d
 */
class Dpq2Connection : dpq2.Connection{
  Duration socketTimeout = dur!"seconds"( 10); ///
  Duration statementTimeout = dur!"seconds"( 30); ///

  this(string connString) @trusted  {
    super( connString);
    setClientEncoding( "UTF8"); // TODO: do only if it is different from UTF8
  }

  /// Blocks while connection will be established or exception thrown
  void reset()  {
    super.resetStart;
    while(true)    {
      if (status() == CONNECTION_BAD)throw new ConnectionException( this);
      if (resetPoll() != PGRES_POLLING_OK)  {
        waitEndOfRead( socketTimeout);
        continue ;
      } else {
        break ;
      }
    }
  }

  // TODO: rename to waitEndOf + add FileDescriptorEvent.Trigger argument
  private auto waitEndOfRead(in Duration timeout)  {
    import vibe.core.core;

    version(Posix){
      import core.sys.posix.fcntl;
      assert((fcntl( this.posixSocket, F_GETFL, 0) & O_NONBLOCK), "Socket assumed to be non-blocking already");
    }
    version(Have_vibe_core){
      // vibe-core right now supports only read trigger event
      // it also closes the socket on scope exit, thus a socket duplication here
      auto event = createFileDescriptorEvent( this.posixSocketDuplicate, FileDescriptorEvent.Trigger.read);
    } else {
      auto event = createFileDescriptorEvent( this.posixSocket, FileDescriptorEvent.Trigger.any);
    }
    return event;
  }

  private void waitEndOfReadAndConsume(in Duration timeout) {
    auto event = waitEndOfRead( timeout);
    scope(exit) destroy( event); // Prevents 100% CPU usage
    do {
      if (!event.wait( timeout)) throw new PostgresClientTimeoutException( __FILE__, __LINE__);
      consumeInput();
    }
    while (this.isBusy); // wait until PQgetresult won't block anymore
  }

  private void doQuery(void delegate() doesQueryAndCollectsResults) {
    // Try to get usable connection and send SQL command
    while(true) {
      if (status() == CONNECTION_BAD)
        throw new ConnectionException( this, __FILE__, __LINE__);

      if (poll() != PGRES_POLLING_OK){
        waitEndOfReadAndConsume( socketTimeout);
        continue ;
      } else {
        break ;
      }
    }
    doesQueryAndCollectsResults();
  }

  private immutable(Result) runStatementBlockingManner(void delegate() sendsStatementDg) {
    immutable(Result)[] res;
    runStatementBlockingMannerWithMultipleResults( sendsStatementDg, (r){
      res ~= r;
    }, false);
    enforce( res.length == 1, "Simple query without row-by-row mode can return only one Result instance, not "~res.length.to!string);
    return res[0];
  }

  private void runStatementBlockingMannerWithMultipleResults(void delegate() sendsStatementDg, void delegate(immutable(Result)) processResult, bool isRowByRowMode) {
    immutable(Result)[] res;

    doQuery( (){
      sendsStatementDg();
      scope(exit) {
        consumeInput(); // TODO: redundant call (also called in waitEndOfRead) - can be moved into catch block?
        while(true){
          auto r = getResult();
          if (status == CONNECTION_BAD) throw new ConnectionException( this, __FILE__, __LINE__);
          if (r is null) break ;
          processResult( r);
        }
      }

      try{
        waitEndOfReadAndConsume( statementTimeout);
      }catch(PostgresClientTimeoutException e){
        try
        cancel(); // cancel sql query
        catch(CancellationException ce) // means successful cancellation
        e.msg ~= ", "~ce.msg;
        throw e;
      }
    }
    );
  }

  immutable(Answer) execStatement(string sqlCommand,ValueFormat resultFormat = ValueFormat.BINARY) {
    QueryParams p;
    p.resultFormat = resultFormat;
    p.sqlCommand = sqlCommand;
    return execStatement( p);
  }

  immutable(Answer) execStatement(in ref QueryParams params) {
    auto res = runStatementBlockingManner( {
      sendQueryParams( params);
    });
    return res.getAnswer;
  }
}

class PostgresClientTimeoutException : Dpq2Exception{
  this(string file, size_t line) {
    super( "Exceeded Posgres query time limit", file, line);
  }
}
