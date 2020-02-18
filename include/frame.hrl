-record(frame, {
                mtype,
                devaddr,
                ack = 0,
                adr = 0,
                adrackreq = 0,
                rfu = 0,
                fpending = 0,
                fcnt,
                fopts = [],
                fport,
                data,
                device
               }).