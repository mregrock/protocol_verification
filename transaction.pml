#define TIMEOUT 5


typedef Config {
    int version = 0;
}

inline assign_config(dest, src) {
    dest.version = src.version;
}

inline invalidate_config(dest) {
    dest.version = -1;
}

inline try_harakiri(self, label) {
    if
    :: self.generation < 2 ->
        goto label;
    :: true ->
        skip;
    fi
}

typedef Tablet {
    int generation;
    Config proposed;
    Config commit;
    int timer = 0;
}


Tablet bsc_tablet;
Tablet console_tablet;

mtype = {grpc_request, validate_request, validate_response_ok, validate_response_fail, commit_request, commit_response, 
grpc_response_ok, grpc_response_fail, make_connection};

typedef Message {
    Config config;
    mtype type;
}


chan pipe_grpc_proxy_to_bsc = [3] of {Message};
chan pipe_bsc_to_console = [3] of {Message};
chan pipe_console_to_bsc = [3] of {Message};
chan pipe_bsc_to_grpc_proxy = [3] of {Message};

bool bsc_ended_work = false;
int grpc_result_ok = -1;
proctype grpc_proxy() {
    Message msg;
    msg.config.version = 1;
    pipe_grpc_proxy_to_bsc!msg;
    pipe_bsc_to_grpc_proxy?msg;
    if
    :: msg.type == grpc_response_ok ->
        grpc_result_ok = 1;
    :: msg.type == grpc_response_fail ->
        grpc_result_ok = 0;
    fi
}

proctype bsc() {
    Message msg;
    bool answered_grpc = false;
    bool get_message_from_grpc_proxy = false;
bsc_start:
    do
    :: pipe_grpc_proxy_to_bsc?msg -> 
        get_message_from_grpc_proxy = true;
        if
        :: msg.config.version > bsc_tablet.commit.version && bsc_tablet.proposed.version == -1 ->
            assign_config(bsc_tablet.proposed, msg.config);
            printf("BSC: assign proposed from grpc proxy %d\n", bsc_tablet.proposed.version);
            msg.type = validate_request;
            pipe_bsc_to_console!msg;
        :: else ->
            msg.type = grpc_response_fail;
            printf("BSC: send grpc response fail when version is not ok\n");
            pipe_bsc_to_grpc_proxy!msg;
            answered_grpc = true;
            break;
        fi
    :: pipe_console_to_bsc?msg -> 
        if
        :: msg.type == make_connection ->
            if
            :: bsc_tablet.commit.version > 0 ->
                msg.type = commit_request;
                pipe_bsc_to_console!msg;
            :: else ->
                skip;
            fi
        :: msg.type == validate_response_ok ->
            if
            :: bsc_tablet.proposed.version == msg.config.version ->
                assign_config(bsc_tablet.commit, bsc_tablet.proposed);
                printf("BSC: assign commit from proposed after validate ok %d\n", bsc_tablet.commit.version);
                invalidate_config(bsc_tablet.proposed);
                msg.type = commit_request;
                pipe_bsc_to_console!msg;
                msg.type = grpc_response_ok;
                printf("BSC: send grpc response ok when validate ok and version is ok\n");
                pipe_bsc_to_grpc_proxy!msg;
                answered_grpc = true;
            :: else ->
                skip;
            fi
        :: msg.type == validate_response_fail ->
            invalidate_config(bsc_tablet.proposed);
            printf("BSC: invalidate proposed after validate fail %d\n", bsc_tablet.proposed.version);
            msg.type = grpc_response_fail;
            pipe_bsc_to_grpc_proxy!msg;
            answered_grpc = true;
            break;
        :: msg.type == commit_response ->
            break;
        fi
    :: bsc_tablet.timer < TIMEOUT ->
        bsc_tablet.timer = bsc_tablet.timer + 1;
    :: bsc_tablet.timer >= TIMEOUT && !answered_grpc && get_message_from_grpc_proxy ->
        invalidate_config(bsc_tablet.proposed);
        printf("BSC: invalidate proposed and fail grpc after timeout %d\n", bsc_tablet.proposed.version);
        msg.type = grpc_response_fail;
        pipe_bsc_to_grpc_proxy!msg;
        answered_grpc = true;
    :: true -> // dead
        invalidate_config(bsc_tablet.proposed);
        printf("BSC: invalidate proposed after dead %d\n", bsc_tablet.proposed.version);
        if
        :: !answered_grpc && get_message_from_grpc_proxy ->
            printf("BSC: send grpc response fail when dead %d\n", bsc_tablet.proposed.version);
            msg.type = grpc_response_fail;
            pipe_bsc_to_grpc_proxy!msg;
            answered_grpc = true;
        :: else ->
            skip;
        fi
    od
    bsc_ended_work = true;
}

proctype console() {
    Message msg;
console_start:
    msg.type = make_connection
    pipe_console_to_bsc!msg;
    do
    :: pipe_bsc_to_console?msg ->
        if
        :: msg.type == validate_request ->
            try_harakiri(console_tablet, console_start);
            assign_config(console_tablet.proposed, msg.config);
            printf("CONSOLE: assign proposed from bsc %d\n", console_tablet.proposed.version);
            try_harakiri(console_tablet, console_start);
            if
            :: true ->
                msg.type = validate_response_ok;
            :: true ->
                msg.type = validate_response_fail;
                invalidate_config(console_tablet.proposed);
                printf("CONSOLE: invalidate proposed %d\n", console_tablet.proposed.version);
            fi
            pipe_console_to_bsc!msg;
            try_harakiri(console_tablet, console_start);
        :: msg.type == commit_request ->
            try_harakiri(console_tablet, console_start);
            assign_config(console_tablet.commit, msg.config);
            printf("CONSOLE: assign commit from bsc %d\n", console_tablet.commit.version);
            invalidate_config(console_tablet.proposed);
            printf("CONSOLE: invalidate proposed %d\n", console_tablet.proposed.version);
            try_harakiri(console_tablet, console_start);
            msg.type = commit_response;
            pipe_console_to_bsc!msg;
        fi
    :: bsc_ended_work ->
        break;
    od
    skip;
}

init {
    invalidate_config(bsc_tablet.proposed);
    invalidate_config(console_tablet.proposed);
    atomic {
        run grpc_proxy();
        run bsc();
        run console();
    }
    skip;
}

#define GRPC_RESULT_OK ((grpc_result_ok == 1 -> <>(bsc_tablet.commit.version == 1 && console_tablet.commit.version == 1)))
#define GRPC_RESULT_FAIL ((grpc_result_ok == 0 -> <>(bsc_tablet.commit.version == 0 && console_tablet.commit.version == 0)))
ltl proof_of_work {
    [] ((bsc_ended_work -> (GRPC_RESULT_OK && GRPC_RESULT_FAIL && <> (bsc_tablet.proposed.version == -1 && console_tablet.proposed.version == -1))));
}