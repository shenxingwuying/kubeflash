#!/bin/expect

set RSA_PATH [lindex $argv 0]
set USER [lindex $argv 1]
set PASSWD [lindex $argv 2]
set HOST [lindex $argv 3]

set timeout 10
spawn ssh-copy-id -i ${RSA_PATH} ${USER}@${HOST}

expect {
    "*password:" {
        send "${PASSWD}\r"
    }
    "*already exist on the remote system*"
    {
    }
}
interact