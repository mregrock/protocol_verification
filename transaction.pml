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
    Config state;
    Config commit;
    int timer = 0;
}


Tablet bsc_tablet;
Tablet console_tablet;

mtype = {grpc_request, init_commit, init_commit_ack, init_commit_fail, commit_request, commit_response, question, question_ack, grpc_response, abort_request, abort_response};

typedef Message {
    Config config;
    mtype type;
}


chan pipe_grpc_proxy_to_bsc = [3] of {Message};
chan pipe_bsc_to_console = [3] of {Message};
chan pipe_console_to_bsc = [3] of {Message};
chan pipe_bsc_to_grpc_proxy = [3] of {Message};

proctype grpc_proxy() {
    Message msg;
    msg.config.version = 1;
    pipe_grpc_proxy_to_bsc!msg;
    pipe_bsc_to_grpc_proxy?msg;
}

proctype bsc() {
    Message msg;
bsc_start:
    do
    :: pipe_grpc_proxy_to_bsc?msg -> 
        if
        :: msg.config.version == bsc_tablet.state.version ->
            assign_config(bsc_tablet.state, msg.config);
            msg.type = init_commit;
            pipe_bsc_to_grpc_proxy!msg;
    :: pipe_console_to_bsc?msg -> 
        if
        :: msg.type == init_commit_ack->
            assign_config(bsc_tablet.commit, msg.config);
            msg.type = commit_request;
            pipe_bsc_to_console!msg;
            msg.type = grpc_response;
            pipe_bsc_to_grpc_proxy!msg;
        :: msg.type == init_commit_fail ->
            invalidate_config(bsc_tablet.state);
            msg.type = grpc_response;
            pipe_bsc_to_grpc_proxy!msg;
            break;
        :: msg.type == commit_response ->
            break;
        :: msg.type == question && msg.config.version == bsc_tablet.commit.version ->
            msg.type = commit_request;
            pipe_bsc_to_console!msg;
        :: msg.type == question && msg.config.version != bsc_tablet.commit.version ->
            msg.type = abort_request;
            pipe_bsc_to_console!msg;
        :: msg.type == abort_response ->
            break;
        fi
    :: true -> // dead
       invalidate_config(bsc_tablet.state);
       msg.type = grpc_response;
       pipe_bsc_to_grpc_proxy!msg;
    :: bsc_tablet.timer < TIMEOUT ->
        bsc_tablet.timer = bsc_tablet.timer + 1;
    :: bsc_tablet.timer >= TIMEOUT ->
        invalidate_config(bsc_tablet.state);
        msg.type = grpc_response;
        pipe_bsc_to_grpc_proxy!msg;
    od
}

proctype console() {
    Message msg;
console_start:
    if
    :: console_tablet.state.version != -1 ->
        msg.type = question;
        pipe_console_to_bsc!msg;
    :: else ->
        skip;
    fi
    do
    :: pipe_bsc_to_console?msg ->
        if
        :: msg.type == init_commit ->
            try_harakiri(console_tablet, console_start);
            assign_config(console_tablet.state, msg.config);
            try_harakiri(console_tablet, console_start);
            msg.type = init_commit_ack;
            pipe_console_to_bsc!msg;
            try_harakiri(console_tablet, console_start);
        :: msg.type == commit_request ->
            try_harakiri(console_tablet, console_start);
            assign_config(console_tablet., msg.config);
            try_harakiri(console_tablet, console_start);
            msg.type = commit_response;
            pipe_console_to_bsc!msg;
        fi
    od
    skip;
}

init {
    invalidate_config(bsc_tablet.state);
    invalidate_config(console_tablet.state);
    skip;
}
