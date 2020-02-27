-record(device, {
                 id,
                 name,
                 dev_eui,
                 app_eui,
                 nwk_s_key,
                 app_s_key,
                 join_nonce,
                 fcnt=0,
                 fcntdown=0,
                 offset=0,
                 channel_correction=false,
                 queue=[]
                }).

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
                data
               }).
