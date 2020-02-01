-record(device, {
                 mac,
                 app_eui,
                 nwk_s_key,
                 app_s_key,
                 join_nonce,
                 fcnt,
                 fcntdown=0,
                 offset=0,
                 channel_correction=false,
                 queue=[]
                }).