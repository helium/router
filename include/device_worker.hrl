-record(frame, {
                mtype,
                dev_addr,
                ack = 0,
                adr = 0,
                adrackreq = 0,
                rfu = 0,
                fpending = 0,
                fcnt,
                fopts = [],
                fport,
                data
               }).