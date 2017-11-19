#!/usr/bin/tclsh

package require sha1
package require json
package require json::write

set PORT 4001
set WSGUID 258EAFA5-E914-47DA-95CA-C5AB0DC85B11

set verbose no
set debug no

foreach opt $::argv {
  switch $opt {
    -v {set verbose yes}
    -d {set debug yes}
  }
}

proc vim-send {name msg} { exec gvim --servername $name --remote-send $msg }
proc vim-expr {name expr} { exec gvim --servername $name --remote-expr $expr }

proc vim-launch {name} {
    exec gvim -c "set buftype=nofile" -c "set bufhidden=hide" -c "set noswapfile" --servername $name &

    while {[incr attempts] < 10 && [catch {vim-expr $chan changenr()}]} {
      after 250
    }
}

set quit 0

proc xor {payload mask} {
  set len [string length $payload]
  # binary scan i only reads in multiples of 4, so pad the string
  binary scan "$payload..." i* payload
  string range [
    binary format i* [lmap x $payload {expr {$x ^ $mask}}]
  ] 0 $len-1
}

proc stringify {dictVal} {
  foreach {k v} $dictVal {
    lappend a "[json::write::string $k]:[json::write::string $v]"
  }
  return [list [join $a ,]]
}

proc every {ms body {last {}}} {
  global every
  if {$ms == "cancel"} {
    if {[info exists every($body)]} {
      after cancel $every($body)
      unset every($body)
    }
  } else {
    if {[info exists every($body)]} {
      after cancel $every($body)
    }
    if {[set last [eval $body $last]] != "end"} {
      set every($body) [after $ms every $ms [list $body] $last]
    }
  }
}

proc send {chan packet} {
  puts -nonewline $chan $packet
  flush $chan
}

proc onclose {chan} {
  if {![eof $chan]} {
    set packet [binary format H2c 88 0]; # fin, close, zero unmasked length
    send $chan $packet
  }

  every cancel [list refresh $chan]
  lassign [chan configure $chan -peername] addr host port
  close $chan
  if {$::verbose} { puts "WebSocket $addr:$port disconnected." }

  if {[catch {
    vim-send $chan {:q<CR>}
  } exc]} {
    puts "Exception while closing VIm: $exc"
  }
}

proc refresh {chan {change {}}} {
  if {[catch {
    set nchange [vim-expr $chan changenr()]
    if {$nchange != $change} {
      if {"n" != [vim-expr $chan mode()]} {
        # we're editing, wait for the edit to finish.
        set nchange $change
      } else {
        set buf [vim-expr $chan {getline(1,'$')}]
      }
    }
  } exc]} {
    puts "Exception querying VIm: $exc"
    onclose $chan
    return end
  } elseif {$nchange != $change} {
    if {$::verbose} { puts "Update detected, sending..." }
    if {$::debug} { puts "Sending: $buf" }
    set change $nchange
    set buf [stringify [list text $buf]]
    set len [string length $buf]
    if {$len >= 65536} {
      set blen [binary format cII 127 0 $len]
    } elseif {$len >= 126} {
      set blen [binary format cS 126 $len]
    } else {
      set blen [binary format c $len]
    }
    # puts "sending $buf"
    # rfc6455 5.1 ... A server MUST NOT mask any frames
    set packet "[binary format H2 81]$blen$buf"
    send $chan $packet
    flush $chan
  }
  return $change
}

proc onmessage {chan} {
  if {[catch {
    if {[eof $chan]} {
      onclose $chan
    } else {
      set preamble [read $chan 1]
      set masklen [read $chan 1]
      binary scan $preamble b4 flags
      binary scan $preamble h opcode
      binary scan $masklen B masked
      binary scan $masklen c len
      if {$len < 0} {set len [expr {$len & 127}]}

      if {$len == 126} {
        # 16 bit length.
        binary scan [read $chan 2] S len
      } elseif {$len == 127} {
        binary scan [read $chan 8] II over len
        if {$over != 0 || $len < 0} {
          puts "Oversized packet; closing. ($over:$len)"
          onclose $chan
          return
        }
      }
      # rfc6455 5.1 ... A client MUST mask all frames
      if {$masked} {binary scan [read $chan 4] i mask} {onclose $chan; return}
      if {$len < 0} {set len [expr {65536 + $len}]}
      if {$::debug} {
        puts "FLAGS:$flags OPCODE:$opcode MASKED:$masked LEN:$len MASK:$mask"
      }

      set payload [xor [read $chan $len] $mask]
      # puts $payload

      switch $opcode {
        1 {
          # text
          set msg [json::json2dict $payload]
          set txt "\[\"[join [lmap x [split [dict get $msg text] "\n"] {set x [regsub -all "\"" $x {\"}]}] {","}]\"\]"
          lassign [vim-expr $chan getcurpos()] bnum lnum col
          # tcl can't have '<' at the begging of an exec-parameter, so
          # we can't send <ESC> first...
          vim-send $chan {:%d _<CR>}
          vim-expr $chan "append(0,$txt)"
          # there's always one empty line after deleting them all, remove it.
          vim-send $chan {:$d _<CR>}
          vim-expr $chan "cursor($lnum,$col)"

          every 1000 [list refresh $chan] [vim-expr $chan changenr()]
        }
        8 {
          # close
          onclose $chan
        }
        9 {
          ; # ping
          puts "Ping? Pong."
          set packet [binary format H2c 8a 0]; # fin, pong, zero unmasked length
          send $chan $packet
        }
        a {
          # pong
          puts "Pong."
        }

        default {
          puts "Unknown opcode: $opcode"
        }
      }
    }
  } exc]} {
    puts "Caught exception: $exc"
  }
}

proc sl {chan {msg {}}} {
  # puts $msg
  puts $chan "$msg"
}

proc accept {chan addr port} {
  global PORT WSGUID
  fconfigure $chan -translation crlf
  while {![eof $chan]} {
    set l [string trim [gets $chan]]
    if {[string equal $l ""]} break
    set h [lindex $l 0]
    set v [lreplace $l 0 0]
    set rq($h) $v
  }

  if {[info exists rq(Upgrade:)] && [string equal websocket $rq(Upgrade:)]} {
    if {$::verbose} { puts "WebSocket $addr:$port connected." }
    if {$::debug} { puts "WebSocket [array get rq Sec-*]" }
    sl $chan "HTTP/1.1 101 Switching Protocols"
    sl $chan "Date: [clock format [clock seconds] -format {%a, %d %h %Y %T %Z} -timezone GMT]"
    sl $chan "Server: ..."
    sl $chan "Upgrade: $rq(Upgrade:)"
    sl $chan "Connection: Upgrade"
    sl $chan "Sec-WebSocket-Accept: [
      binary encode base64 [
        binary decode hex [sha1::sha1 "$rq(Sec-WebSocket-Key:)$WSGUID"]
      ]
    ]"
    sl $chan
    flush $chan
    fconfigure $chan -translation binary -blocking 0

    vim-launch $chan

    fileevent $chan readable [list onmessage $chan]
  } else {
    if {$::verbose} { puts "HTTP $addr:$port connected." }
    # don't know why we do this extra request, just keep using the same port.
    set payload [subst {{"WebSocketPort":$PORT,"ProtocolVersion":1}}]
    sl $chan "HTTP/1.1 200 Ok"
    sl $chan "Date: [clock format [clock seconds] -format {%a, %d %h %Y %T %Z} -timezone GMT]"
    sl $chan "Server: ..."
    sl $chan "Content-Type: application/json"
    sl $chan "Connection: close"
    # sl $chan "Content-Length: [string length $payload]"
    sl $chan
    sl $chan $payload
    sl $chan
    close $chan
    if {$::verbose} { puts "HTTP $addr:$port disconnected." }
  }
}

if {$::verbose} { puts "Listening on $PORT"; }
socket -server accept -myaddr localhost $PORT
vwait quit
