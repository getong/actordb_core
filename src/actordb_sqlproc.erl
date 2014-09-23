% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
-module(actordb_sqlproc).
-behaviour(gen_server).
-define(LAGERDBG,true).
-export([start/1, stop/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([print_info/1]).
-export([read/4,write/4,call/4,call/5,diepls/2,try_actornum/3]).
-export([call_slave/4,call_slave/5,start_copylock/2]). %call_master/4,call_master/5
-export([write_call/3]).
-include_lib("actordb_sqlproc.hrl").

% Read actor number without creating actor.
try_actornum(Name,Type,CbMod) ->
	case call({Name,Type},[actornum],{state_rw,actornum},CbMod) of
		{error,nocreate} ->
			{"",undefined};
		{ok,Path,NumNow} ->
			{Path,NumNow}
	end.

read(Name,Flags,[{copy,CopyFrom}],Start) ->
	case distreg:whereis(Name) of
		undefined ->
			case call(Name,Flags,{read,<<"select * from __adb limit 1;">>},Start) of
				{ok,_} ->
					{ok,[{columns,{<<"status">>}},{row,{<<"ok">>}}]};
				_E ->
					?AERR("Unable to copy actor ~p to ~p",[CopyFrom,Name]),
					{ok,[{columns,{<<"status">>}},{row,{<<"failed">>}}]}
			end;
		Pid ->
			diepls(Pid,overwrite),
			Ref = erlang:monitor(process,Pid),
			receive
				{'DOWN',Ref,_,_Pid,_} ->
					read(Name,Flags,[{copy,CopyFrom}],Start)
				after 2000 ->
					{ok,[{columns,{<<"status">>}},{row,{<<"failed_running">>}}]}
			end
	end;
read(Name,Flags,[delete],Start) ->
	call(Name,Flags,#write{sql = delete,transaction = {0,0,<<>>}},Start);
read(Name,Flags,Sql,Start) ->
	call(Name,Flags,{read,Sql},Start).

write(Name,Flags,{{_,_,_} = TransactionId,Sql},Start) ->
	write(Name,Flags,{undefined,TransactionId,Sql},Start);
write(Name,Flags,{MFA,TransactionId,Sql},Start) ->
	case TransactionId of
		{_,_,_} ->
			case Sql of
				commit ->
					call(Name,Flags,{commit,true,TransactionId},Start);
				abort ->
					call(Name,Flags,{commit,false,TransactionId},Start);
				[delete] ->
					call(Name,Flags,#write{mfa = MFA,sql = delete, transaction = TransactionId},Start);
				_ ->
					call(Name,Flags,#write{mfa = MFA,sql = iolist_to_binary(Sql), transaction = TransactionId},Start)
			end;
		_ when Sql == undefined ->
			call(Name,Flags,#write{mfa = MFA},Start);
		_ ->
			call(Name,[wait_election|Flags],#write{mfa = MFA, sql = iolist_to_binary(Sql)},Start)
	end;
write(Name,Flags,[delete],Start) ->
	% Delete actor calls are placed in a fake multi-actor transaction. 
	% This way if the intent to delete is written, then actor will actually delete itself.
	call(Name,Flags,#write{sql = delete,transaction = {0,0,<<>>}},Start);
write(Name,Flags,{Sql,Records},Start) ->
	call(Name,[wait_election|Flags],#write{sql = iolist_to_binary(Sql), records = Records},Start);
write(Name,Flags,Sql,Start) ->
	call(Name,[wait_election|Flags],#write{sql = iolist_to_binary(Sql)},Start).


call(Name,Flags,Msg,Start) ->
	call(Name,Flags,Msg,Start,false).
call(Name,Flags,Msg,Start,IsRedirect) ->
	case distreg:whereis(Name) of
		undefined ->
			case startactor(Name,Start,[{startreason,Msg}|Flags]) of %
				{ok,Pid} when is_pid(Pid) ->
					call(Name,Flags,Msg,Start,IsRedirect,Pid);
				{error,nocreate} ->
					{error,nocreate};
				Res ->
					Res
			end;
		Pid ->
			% ?INF("Call have pid ~p for name ~p, alive ~p",[Pid,Name,erlang:is_process_alive(Pid)]),
			call(Name,Flags,Msg,Start,IsRedirect,Pid)

	end.
call(Name,Flags,Msg,Start,IsRedirect,Pid) ->
	% If call returns redirect, this is slave node not master node.
	% test_mon_calls(Name,Msg),
	case catch gen_server:call(Pid,Msg,infinity) of
		{redirect,Node} when is_binary(Node) ->
			% test_mon_stop(),
			case lists:member(Node,bkdcore:cluster_nodes()) of
				true ->
					case IsRedirect of
						true ->
							double_redirect;
						_ ->
							case actordb:rpc(Node,element(1,Name),{?MODULE,call,[Name,Flags,Msg,Start,true]}) of
								double_redirect ->
									diepls(Pid,nomaster),
									call(Name,Flags,Msg,Start);
								Res ->
									Res
							end
					end;
				false ->
					case IsRedirect of
						onlylocal ->
							{redirect,Node};
						_ ->
							actordb:rpc(Node,element(1,Name),{?MODULE,call,[Name,Flags,Msg,Start,false]})
					end
			end;
		{'EXIT',{noproc,_}} = _X  ->
			?ADBG("noproc call again ~p",[_X]),
			call(Name,Flags,Msg,Start);
		{'EXIT',{normal,_}} ->
			?ADBG("died normal"),
			call(Name,Flags,Msg,Start);
		{'EXIT',{nocreate,_}} ->
			% test_mon_stop(),
			{error,nocreate};
		Res ->
			% test_mon_stop(),
			Res
	end.
startactor(Name,Start,Flags) ->
	case Start of
		{Mod,Func,Args} ->
			apply(Mod,Func,[Name|Args]);
		undefined ->
			{ok,undefined};
		_ ->
			apply(Start,start,[Name,Flags])
	end.

% test_mon_calls(Who,Msg) ->
% 	Ref = make_ref(),
% 	put(ref,Ref),
% 	put(refpid,spawn(fun() -> test_mon_proc(Who,Msg,Ref) end)).
% test_mon_proc(Who,Msg,Ref) ->
% 	receive
% 		Ref ->
% 			ok
% 		after 1000 ->
% 			?AERR("Still waiting on ~p, for ~p",[Who,Msg]),
% 			test_mon_proc(Who,Msg,Ref)
% 	end.
% test_mon_stop() ->
% 	butil:safesend(get(refpid), get(ref)).


call_slave(Cb,Actor,Type,Msg) ->
	call_slave(Cb,Actor,Type,Msg,[]).
call_slave(Cb,Actor,Type,Msg,Flags) ->
	actordb_util:wait_for_startup(Type,Actor,0),
	case apply(Cb,cb_slave_pid,[Actor,Type,[{startreason,Msg}|Flags]]) of %
		{ok,Pid} ->
			ok;
		Pid when is_pid(Pid) ->
			ok
	end,
	case catch gen_server:call(Pid,Msg,infinity) of
		{'EXIT',{noproc,_}} ->
			call_slave(Cb,Actor,Type,Msg);
		{'EXIT',{normal,_}} ->
			call_slave(Cb,Actor,Type,Msg);
		Res ->
			Res
	end.

diepls(Pid,Reason) ->
	gen_server:cast(Pid,{diepls,Reason}).

start_copylock(Fullname,O) ->
	start_copylock(Fullname,O,0).
start_copylock(Fullname,Opt,N) when N < 2 ->
	case distreg:whereis(Fullname) of
		undefined ->
			start(Opt);
		_ ->
			timer:sleep(1000),
			start_copylock(Fullname,Opt,N+1)
	end;
start_copylock(Fullname,_,_) ->
	Pid = distreg:whereis(Fullname),
	print_info(Pid),
	{error,{slave_proc_running,Pid,Fullname}}.

% Opts:
% [{actor,Name},{type,Type},{mod,CallbackModule},{state,CallbackState},
%  {inactivity_timeout,SecondsOrInfinity},{slave,true/false},{copyfrom,NodeName},{copyreset,{Mod,Func,Args}}]
start(Opts) ->
	?ADBG("Starting ~p slave=~p",[butil:ds_vals([actor,type],Opts),butil:ds_val(slave,Opts)]),
	Ref = make_ref(),
	case gen_server:start(?MODULE, [{start_from,{self(),Ref}}|Opts], []) of
		{ok,Pid} ->
			{ok,Pid};
		{error,normal} ->
			% Init failed gracefully. It should have sent an explanation. 
			receive
				{Ref,nocreate} ->
					{error,nocreate};
				{Ref,{registered,Pid}} ->
					{ok,Pid};
				{Ref,{actornum,Path,Num}} ->
					{ok,Path,Num};
				{Ref,{ok,[{columns,_},_]} = Res} ->
					Res;
				{Ref,nostart} ->
					{error,nostart}
				after 0 ->
					{error,cantstart}
			end;
		Err ->
			?AERR("start sqlproc error ~p",[Err]),
			Err
	end.

stop(Pid) when is_pid(Pid) ->
	Pid ! stop;
stop(Name) ->
	case distreg:whereis(Name) of
		undefined ->
			ok;
		Pid ->
			stop(Pid)
	end.

print_info(Pid) ->
	gen_server:cast(Pid,print_info).



handle_call(Msg,_,P) when is_binary(P#dp.movedtonode) ->
	?DBG("REDIRECT BECAUSE MOVED TO NODE ~p ~p",[P#dp.movedtonode,Msg]),
	case apply(P#dp.cbmod,cb_redirected_call,[P#dp.cbstate,P#dp.movedtonode,Msg,moved]) of
		{reply,What,NS,Red} ->
			{reply,What,P#dp{cbstate = NS, movedtonode = Red}};
		ok ->
			{reply,{redirect,P#dp.movedtonode},P#dp{activity = make_ref()}}
	end;
handle_call({dbcopy,Msg},CallFrom,P) ->
	actordb_sqlprocutil:dbcopy_call(Msg,CallFrom,check_timer(P));
handle_call({state_rw,What},From,P) ->
	state_rw_call(What,From,check_timer(P#dp{activity = make_ref()}));
handle_call({commit,Doit,Id},From, P) ->
	commit_call(Doit,Id,From,P);
handle_call(Msg,From,P) ->
	case Msg of
		_ when P#dp.mors == slave ->
			case P#dp.masternode of
				undefined ->
					?DBG("Queing msg no master yet ~p",[Msg]),
					{noreply,P#dp{callqueue = queue:in_r({From,Msg},P#dp.callqueue), 
									election = actordb_sqlprocutil:election_timer(P#dp.election),
									flags = P#dp.flags band (bnot ?FLAG_WAIT_ELECTION)}};
				_ ->
					case apply(P#dp.cbmod,cb_redirected_call,[P#dp.cbstate,P#dp.masternode,Msg,slave]) of
						{reply,What,NS,_} ->
							{reply,What,P#dp{cbstate = NS}};
						ok ->
							actordb_sqlprocutil:redirect_master(P)
					end
			end;
		_ when P#dp.verified == false ->
			case is_pid(P#dp.election) andalso P#dp.flags band ?FLAG_WAIT_ELECTION > 0 of
				true ->
					P#dp.election ! exit,
					handle_call(Msg,From,P#dp{flags = P#dp.flags band (bnot ?FLAG_WAIT_ELECTION)});
				_ ->
					case apply(P#dp.cbmod,cb_unverified_call,[P#dp.cbstate,Msg]) of
						queue ->
							
							{noreply,P#dp{callqueue = queue:in_r({From,Msg},P#dp.callqueue)}};
						{moved,Moved} ->
							{noreply,check_timer(P#dp{movedtonode = Moved})};
						{moved,Moved,NS} ->
							{noreply,check_timer(P#dp{movedtonode = Moved, cbstate = NS})};
						{reply,What} ->
							{reply,What,P};
						reinit ->
							{ok,NP} = init(P,cb_reinit),
							{noreply,NP};
						{reinit,Sql,NS} ->
							{ok,NP} = init(P#dp{callqueue = queue:in_r({From,#write{sql = Sql}},P#dp.callqueue),
												cbstate = NS},cb_reinit),
							{noreply,NP}
					end
			end;
		#write{transaction = TransactionId} = Msg1 when P#dp.transactionid == TransactionId, P#dp.transactionid /= undefined ->
			write_call(Msg1,From,check_timer(P#dp{activity = make_ref()}));
		_ when P#dp.callres /= undefined; P#dp.locked /= []; P#dp.transactionid /= undefined ->
			?DBG("Queing msg ~p, callres ~p, locked ~p, transactionid ~p",[Msg,P#dp.callres,P#dp.locked,P#dp.transactionid]),
			{noreply,P#dp{callqueue = queue:in_r({From,Msg},P#dp.callqueue)}};
		#write{} = Msg1 ->
			write_call(Msg1,From,check_timer(P#dp{activity = make_ref()}));
		{read,Msg1} ->
			read_call(Msg1,From,check_timer(P#dp{activity = make_ref()}));
		{move,NewShard,Node,CopyReset,CbState} ->
			% Call to move this actor to another cluster. 
			% First store the intent to move with all needed data. This way even if a node chrashes, the actor will attempt to move
			%  on next startup.
			% When write done, reply to caller and start with move process (in ..util:reply_maybe.
			Sql = <<"$INSERT INTO __adb (id,val) VALUES (",?COPYFROM/binary,",'",
						(base64:encode(term_to_binary({{move,NewShard,Node},CopyReset,CbState})))/binary,"');">>,
			write_call(#write{sql = Sql},{exec,From,{move,Node}},check_timer(actordb_sqlprocutil:set_followers(true,P)));
		{split,MFA,Node,OldActor,NewActor,CopyReset,CbState} ->
			% Similar to above. Both have just insert and not insert and replace because
			%  we can only do one move/split at a time. It makes no sense to do both at the same time.
			% So rely on DB to return error for these conflicting calls.
			Sql = <<"$INSERT INTO __adb (id,val) VALUES (",?COPYFROM/binary,",'",
						(base64:encode(term_to_binary({{split,MFA,Node,OldActor,NewActor},CopyReset,CbState})))/binary,"');">>,
			% Split is called when shards are moving around (nodes were added). If different number of nodes in cluster, we need
			%  to have an updated list of nodes.
			write_call(#write{sql = Sql},{exec,From,{split,MFA,Node,OldActor,NewActor}},
				check_timer(actordb_sqlprocutil:set_followers(true,P)));
		{copy,{Node,OldActor,NewActor}} ->
			Ref = make_ref(),
			case actordb:rpc(Node,NewActor,{?MODULE,call,[{NewActor,P#dp.actortype},[{lockinfo,wait},lock],
							{dbcopy,{start_receive,{actordb_conf:node_name(),OldActor},Ref}},P#dp.cbmod]}) of
				ok ->
					actordb_sqlprocutil:dbcopy_call({send_db,{Node,Ref,false,NewActor}},From,check_timer(P));
				Err ->
					{reply, Err,P}
			end;
		stop ->
			{stop, shutdown, stopped, P};
		Msg ->
			% ?DBG("cb_call ~p",[{P#dp.cbmod,Msg}]),
			case apply(P#dp.cbmod,cb_call,[Msg,From,P#dp.cbstate]) of
				{write,Sql,NS} ->
					write_call(#write{sql = Sql},From,P#dp{cbstate = NS});
				{reply,Resp,S} ->
					{reply,Resp,P#dp{cbstate = S}};
				{reply,Resp} ->
					{reply,Resp,P}
			end
	end.


commit_call(Doit,Id,From,P) ->
	?DBG("Commit doit=~p, id=~p, from=~p, trans=~p",[Doit,Id,From,P#dp.transactionid]),
	case P#dp.transactionid == Id of
		true ->
			case P#dp.transactioncheckref of
				undefined ->
					ok;
				_ ->
					erlang:demonitor(P#dp.transactioncheckref)
			end,
			?DBG("Commit write ~p",[P#dp.transactioninfo]),
			{Sql,EvNum,_NewVers} = P#dp.transactioninfo,
			case Doit of
				true when Sql == <<"delete">> ->
					actordb_sqlprocutil:delete_actor(P),
					reply(From,ok),
					?DBG("Commit delete"),
					{stop,normal,P#dp{db = undefined}};
				true when P#dp.follower_indexes == [] ->
					ok = actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,<<"RELEASE SAVEPOINT 'adb';">>)),
					{reply,ok,actordb_sqlprocutil:doqueue(P#dp{transactionid = undefined,transactioncheckref = undefined,
							 transactioninfo = undefined, activity = make_ref(),
							 evnum = EvNum, evterm = P#dp.current_term})};
				true ->
					% We can safely release savepoint.
					% This will send the remaining WAL pages to followers that have commit flag set.
					% Followers will then rpc back appendentries_response.
					% We can also set #dp.evnum now.
					ok = actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,<<"RELEASE SAVEPOINT 'adb';">>,
												P#dp.evterm,EvNum,<<>>)),
					{noreply,ae_timer(P#dp{callfrom = From, activity = make_ref(),
								  callres = ok,evnum = EvNum,
								  follower_indexes = update_followers(EvNum,P#dp.follower_indexes),
								 transactionid = undefined, transactioninfo = undefined,transactioncheckref = undefined})};
				false when P#dp.follower_indexes == [] ->
					case Sql of
						<<"delete">> ->
							ok;
						_ ->
							actordb_sqlite:exec(P#dp.db,<<"ROLLBACK;">>)
					end,
					{reply,ok,actordb_sqlprocutil:doqueue(P#dp{transactionid = undefined, transactioninfo = undefined,
									transactioncheckref = undefined,activity = make_ref()})};
				false ->
					% Transaction failed.
					% Delete it from __transactions.
					% EvNum will actually be the same as transactionsql that we have not finished.
					%  Thus this EvNum section of WAL contains pages from failed transaction and 
					%  cleanup of transaction from __transactions.
					{Tid,Updaterid,_} = P#dp.transactionid,
					case Sql of
						<<"delete">> ->
							ok;
						_ ->
							actordb_sqlite:exec(P#dp.db,<<"ROLLBACK;">>,P#dp.evterm,P#dp.evnum,<<>>)
					end,
					NewSql = <<"DELETE FROM __transactions WHERE tid=",(butil:tobin(Tid))/binary," AND updater=",
										(butil:tobin(Updaterid))/binary,";">>,
					write_call(#write{sql = NewSql},From,P#dp{callfrom = undefined,
										transactionid = undefined,transactioninfo = undefined,transactioncheckref = undefined})
			end;
		_ ->
			{reply,ok,P}
	end.


state_rw_call(What,From,P) ->
	case What of
		actornum ->
			case P#dp.mors of
				master ->
					{reply,{ok,P#dp.dbpath,actordb_sqlprocutil:read_num(P)},P};
				slave when P#dp.masternode /= undefined ->
					actordb_sqlprocutil:redirect_master(P);
				slave ->
					{noreply, P#dp{callqueue = queue:in_r({From,{state_rw,What}},P#dp.callqueue)}}
			end;
		donothing ->
			{reply,ok,P};
		recovered ->
			?DBG("No longer in recovery"),
			{reply,ok,P#dp{inrecovery = false}};
		% Executed on follower.
		% AE is split into multiple calls (because wal is sent page by page as it is written)
		% Start sets parameters. There may not be any wal append calls after if empty write.
		% AEType = [head,empty,recover]
		{appendentries_start,Term,LeaderNode,PrevEvnum,PrevTerm,AEType,CallCount} ->
			?DBG("AE start ~p {PrevEvnum,PrevTerm}=~p leader=~p",[AEType,
												{PrevEvnum,PrevTerm},LeaderNode]),
			case ok of
				_ when P#dp.inrecovery, AEType == head ->
					?DBG("Ignoring head because inrecovery"),
					{reply,false,P};
				_ when is_pid(P#dp.copyproc) ->
					?DBG("Ignoring AE because copy in progress"),
					{reply,false,P};
				_ when Term < P#dp.current_term ->
					?ERR("AE start, input term too old ~p {InTerm,MyTerm}=~p",
							[AEType,{Term,P#dp.current_term}]),
					reply(From,false),
					actordb_sqlprocutil:ae_respond(P,LeaderNode,false,PrevEvnum,AEType,CallCount),
					% Some node thinks its master and sent us appendentries start.
					% Because we are master with higher term, we turn it down.
					% But we also start a new election so that nodes get synchronized.
					case P#dp.mors of
						master ->
							{noreply, actordb_sqlprocutil:start_verify(P,false)};
						_ ->
							{noreply,P}
					end;
				_ when P#dp.mors == slave, P#dp.masternode /= LeaderNode ->
					?DBG("AE start, slave now knows leader ~p ~p",[AEType,LeaderNode]),
					case P#dp.callres /= undefined of
						true ->
							reply(P#dp.callfrom,{redirect,LeaderNode});
						false ->
							ok
					end,
					actordb_local:actor_mors(slave,LeaderNode),
					state_rw_call(What,From,actordb_sqlprocutil:reopen_db(
															P#dp{masternode = LeaderNode, 
															masternodedist = bkdcore:dist_name(LeaderNode), 
															callfrom = undefined, callres = undefined, 
															verified = true, activity = make_ref()}));
				% This node is candidate or leader but someone with newer term is sending us log
				_ when P#dp.mors == master ->
					?ERR("AE start, stepping down as leader ~p ~p",
							[AEType,{Term,P#dp.current_term}]),
					case P#dp.callres /= undefined of
						true ->
							reply(P#dp.callfrom,{redirect,LeaderNode});
						false ->
							ok
					end,
					actordb_local:actor_mors(slave,LeaderNode),
					state_rw_call(What,From,
									actordb_sqlprocutil:save_term(actordb_sqlprocutil:reopen_db(
												P#dp{mors = slave, verified = true, 
													voted_for = undefined,callfrom = undefined, callres = undefined,
													masternode = LeaderNode,activity = make_ref(),
													masternodedist = bkdcore:dist_name(LeaderNode),
													current_term = Term})));
				_ when P#dp.evnum /= PrevEvnum; P#dp.evterm /= PrevTerm ->
					?ERR("AE start attempt failed, evnum evterm do not match, type=~p, {MyEvnum,MyTerm}=~p, {InNum,InTerm}=~p",
								[AEType,{P#dp.evnum,P#dp.evterm},{PrevEvnum,PrevTerm}]),
					% case P#dp.evnum > PrevEvnum andalso  of
					case ok of
						% Node is conflicted, delete last entry
						_ when PrevEvnum > 0, AEType == recover ->
							NP = actordb_sqlprocutil:rewind_wal(P);
						% If false this node is behind. If empty this is just check call.
						% Wait for leader to send an earlier event.
						_ ->
							NP = P
					end,
					reply(From,false),
					actordb_sqlprocutil:ae_respond(NP,LeaderNode,false,PrevEvnum,AEType,CallCount),
					{noreply,NP#dp{activity = make_ref()}};
				_ when Term > P#dp.current_term ->
					?ERR("AE start, my term out of date type=~p {InTerm,MyTerm}=~p",[AEType,{Term,P#dp.current_term}]),
					state_rw_call(What,From,actordb_sqlprocutil:doqueue(actordb_sqlprocutil:save_term(
												P#dp{current_term = Term,voted_for = undefined,
												 masternode = LeaderNode,verified = true,activity = make_ref(),
												 masternodedist = bkdcore:dist_name(LeaderNode)})));
				_ when AEType == empty ->
					?DBG("AE start, ok for empty"),
					reply(From,ok),
					actordb_sqlprocutil:ae_respond(P,LeaderNode,true,PrevEvnum,AEType,CallCount),
					{noreply,P#dp{verified = true,activity = make_ref()}};
				% Ok, now it will start receiving wal pages
				_ ->
					?DBG("AE start ok"),
					{reply,ok,P#dp{verified = true,activity = make_ref(), inrecovery = AEType == recover}}
			end;
		% Executed on follower.
		% sqlite wal, header tells you if done (it has db size in header)
		{appendentries_wal,Term,Header,Body,AEType,CallCount} ->
			case ok of
				_ when Term == P#dp.current_term ->
					actordb_sqlprocutil:append_wal(P,Header,Body),
					case Header of
						% dbsize == 0, not last page
						<<_:32,0:32,_/binary>> ->
							{reply,ok,P#dp{activity = make_ref(),locked = [ae]}};
						% last page
						<<_:32,_:32,Evnum:64/unsigned-big,Evterm:64/unsigned-big,_/binary>> ->
							?DBG("AE WAL done evnum=~p aetype=~p queueempty=~p",
									[Evnum,AEType,queue:is_empty(P#dp.callqueue)]),
							NP = P#dp{evnum = Evnum, evterm = Evterm,activity = make_ref(),locked = []},
							reply(From,ok),
							actordb_sqlprocutil:ae_respond(NP,NP#dp.masternode,true,P#dp.evnum,AEType,CallCount),
							{noreply,NP}
					end;
				_ ->
					?ERR("AE WAL received wrong term ~p",[{Term,P#dp.current_term}]),
					reply(From,false),
					actordb_sqlprocutil:ae_respond(P,P#dp.masternode,false,P#dp.evnum,AEType,CallCount),
					{noreply,P}
			end;
		% Executed on leader.
		{appendentries_response,Node,CurrentTerm,Success,EvNum,EvTerm,MatchEvnum,AEType,CallCount} ->
			Follower = lists:keyfind(Node,#flw.node,P#dp.follower_indexes),
			case Follower of
				false ->
					?DBG("Adding node to follower list ~p",[Node]),
					state_rw_call(What,From,actordb_sqlprocutil:store_follower(P,#flw{node = Node}));
				_ when Follower#flw.call_count > CallCount; P#dp.verified == false ->
					?DBG("ignoring AE response, from=~p, success=~p, type=~p, HisEvNum=~p,cur_call_count=~p, received_count=~p, verified=~p",
							[Node,Success,AEType,Follower#flw.match_index,Follower#flw.call_count, CallCount,P#dp.verified]),
					{reply,ok,P};
				_ ->
					?DBG("AE response, from=~p, success=~p, type=~p, HisOldEvnum=~p, HisEvNum=~p, MatchSent=~p",
							[Node,Success,AEType,Follower#flw.match_index,EvNum,MatchEvnum]),
					NFlw = Follower#flw{match_index = EvNum, match_term = EvTerm,next_index = EvNum+1,
											wait_for_response_since = undefined}, 
					case Success of
						% An earlier response.
						_ when P#dp.mors == slave ->
							?ERR("Received AE response after stepping down"),
							{reply,ok,P};
						true ->
							reply(From,ok),
							NP = actordb_sqlprocutil:reply_maybe(actordb_sqlprocutil:continue_maybe(P,NFlw)),
							?DBG("AE response for node ~p, followers=~p",
									[Node,[{F#flw.node,F#flw.match_index,F#flw.next_index} || F <- NP#dp.follower_indexes]]),
							{noreply,NP};
						% What we thought was follower is ahead of us and we need to step down
						false when P#dp.current_term < CurrentTerm ->
							?DBG("My term is out of date {His,Mine}=~p",[{CurrentTerm,P#dp.current_term}]),
							{reply,ok,actordb_sqlprocutil:reopen_db(actordb_sqlprocutil:save_term(
								P#dp{mors = slave,current_term = CurrentTerm,
									election = actordb_sqlprocutil:election_timer(P#dp.election),
									masternode = undefined, masternodedist = undefined,
									voted_for = undefined, follower_indexes = []}))};
						false when NFlw#flw.match_index == P#dp.evnum ->
							% Follower is up to date. He replied false. Maybe our term was too old.
							{reply,ok,actordb_sqlprocutil:reply_maybe(actordb_sqlprocutil:store_follower(P,NFlw))};
						false ->
							% If we are copying entire db to that node already, do nothing.
							case [C || C <- P#dp.dbcopy_to, C#cpto.node == Node, C#cpto.actorname == P#dp.actorname] of
								[_|_] ->
									?DBG("Ignoring appendendentries false response because copying to"),
									{reply,ok,P};
								[] ->
									case actordb_sqlprocutil:try_wal_recover(P,NFlw) of
										{false,NP,NF} ->
											?DBG("Can not recover from log, sending entire db"),
											% We can not recover from wal. Send entire db.
											Ref = make_ref(),
											case bkdcore:rpc(NF#flw.node,{?MODULE,call_slave,
																[P#dp.cbmod,P#dp.actorname,P#dp.actortype,
																{dbcopy,{start_receive,actordb_conf:node_name(),Ref}}]}) of
												ok ->
													actordb_sqlprocutil:dbcopy_call({send_db,{NF#flw.node,Ref,false,
																								P#dp.actorname}},
																					From,NP);
												_Err ->
													?ERR("Unable to send db ~p",[_Err]),
													{reply,false,P}
											end;
										{true,NP,NF} ->
											% we can recover from wal
											?DBG("Recovering from wal, for node=~p, match_index=~p,myevnum=~p",
													[NF#flw.node,NF#flw.match_index,P#dp.evnum]),
											reply(From,ok),
											{noreply,actordb_sqlprocutil:continue_maybe(NP,NF)}
									end
							end
					end
			end;
		{request_vote,Candidate,NewTerm,LastEvnum,LastTerm} ->
			?DBG("Request vote for=~p, mors=~p, {histerm,myterm}=~p, {HisLogTerm,MyLogTerm}=~p {HisEvnum,MyEvnum}=~p",
					[Candidate,P#dp.mors,{NewTerm,P#dp.current_term},{LastTerm,P#dp.evterm},{LastEvnum,P#dp.evnum}]),
			Uptodate = 
				case ok of
					_ when P#dp.evterm < LastTerm ->
						true;
					_ when P#dp.evterm > LastTerm ->
						false;
					_ when P#dp.evnum < LastEvnum ->
						true;
					_ when P#dp.evnum > LastEvnum ->
						false;
					_ ->
						true
				end,
			case ok of
				% Candidates term is lower than current_term, ignore.
				_ when NewTerm < P#dp.current_term ->
					DoElection = (P#dp.mors == master andalso P#dp.verified == true),
					reply(From,{outofdate,actordb_conf:node_name(),P#dp.current_term,{P#dp.evnum,P#dp.evterm}}),
					NP = P;
				% We've already seen this term, only vote yes if we have not voted
				%  or have voted for this candidate already.
				_ when NewTerm == P#dp.current_term ->
					case (P#dp.voted_for == undefined orelse P#dp.voted_for == Candidate) of
						true when Uptodate ->
							DoElection = false,
							reply(From,{true,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
							NP = actordb_sqlprocutil:save_term(P#dp{voted_for = Candidate, current_term = NewTerm,
																election = actordb_sqlprocutil:election_timer(P#dp.election),
																masternode = undefined, masternodedist = undefined});
						true ->
							DoElection = (P#dp.mors == master andalso P#dp.verified == true),
							reply(From,{outofdate,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
							NP = actordb_sqlprocutil:save_term(P#dp{voted_for = undefined, current_term = NewTerm});
						false ->
							DoElection =(P#dp.mors == master andalso P#dp.verified == true),
							reply(From,{alreadyvoted,actordb_conf:node_name(),P#dp.current_term,{P#dp.evnum,P#dp.evterm}}),
							NP = P
					end;
				% New candidates term is higher than ours, is he as up to date?
				_ when Uptodate ->
					DoElection = false,
					reply(From,{true,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
					NP = actordb_sqlprocutil:save_term(P#dp{voted_for = Candidate, current_term = NewTerm,
																election = actordb_sqlprocutil:election_timer(P#dp.election),
																masternode = undefined, masternodedist = undefined});
				% Higher term, but not as up to date. We can not vote for him.
				% We do have to remember new term index though.
				_ ->
					DoElection = (P#dp.mors == master andalso P#dp.verified == true),
					reply(From,{outofdate,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
					case ok of
						_ when element(1,P#dp.db) == connection ->
							ReplType = apply(P#dp.cbmod,cb_replicate_type,[P#dp.cbstate]),
							ok = esqlite3:replicate_opts(P#dp.db,term_to_binary({P#dp.cbmod,P#dp.actorname,P#dp.actortype,NewTerm}),ReplType);
						_ ->
							ok
					end,
					NP = actordb_sqlprocutil:save_term(P#dp{voted_for = undefined, current_term = NewTerm,
						election = actordb_sqlprocutil:election_timer(P#dp.election)})
			end,
			% If voted no and we are leader, start a new term, which causes a new write and gets all nodes synchronized.
			% If the other node is actually more up to date, vote was yes and we do not do election.
			?DBG("Doing election after request_vote? ~p, mors=~p, verified=~p, election=~p",
					[DoElection,P#dp.mors,P#dp.verified,P#dp.election]),
			case DoElection of
				true ->
					% {noreply,NP#dp{election = actordb_sqlprocutil:election_timer(P#dp.election)}};
					case is_reference(NP#dp.election) of
						true ->
							EE = undefined,
							erlang:cancel_timer(NP#dp.election);
						false when NP#dp.election == undefined ->
							EE = undefined;
						_ ->
							EE = NP#dp.election
					end,
					{noreply,actordb_sqlprocutil:start_verify(actordb_sqlprocutil:set_followers(true,NP#dp{election = EE}),false)};
					% case lists:keyfind(Candidate,#flw.node,P#dp.follower_indexes) of
					% 	false ->
					% 		NP1 = actordb_sqlprocutil:set_followers(true,NP),
					% 		NFlw = actordb_sqlprocutil:send_empty_ae(NP1,Candidate);
					% 	Flw ->
					% 		NP1 = NP,
					% 		NFlw = actordb_sqlprocutil:send_empty_ae(NP,Flw)
					% end,
					% {noreply, actordb_sqlprocutil:store_follower(NP1,NFlw)};
				false ->
					{noreply,NP#dp{activity = make_ref()}}
			end;
		{set_dbfile,Bin} ->
			ok = file:write_file(P#dp.dbpath,esqlite3:lz4_decompress(Bin,?PAGESIZE)),
			{reply,ok,P#dp{activity = make_ref()}};
		% Hint from a candidate that this node should start new election, because
		%  it is more up to date.
		doelection ->
			?DBG("Doelection hint ~p",[{P#dp.verified,P#dp.election}]),
			reply(From,ok),
			case is_pid(P#dp.election) orelse is_reference(P#dp.election) of
				false ->
					{noreply,actordb_sqlprocutil:start_verify(P,false)};
				_ ->
					{noreply,P}
			end;
		{delete,MovedToNode} ->
			reply(From,ok),
			actordb_sqlite:stop(P#dp.db),
			?DBG("Received delete call"),
			actordb_sqlprocutil:delactorfile(P#dp{movedtonode = MovedToNode}),
			{stop,normal,P#dp{db = undefined}};
		checkpoint ->
			actordb_sqlprocutil:do_checkpoint(P),
			{reply,ok,P}
	end.

read_call([exists],_From,#dp{mors = master} = P) ->
	{reply,{ok,[{columns,{<<"exists">>}},{rows,[{<<"true">>}]}]},P};
read_call(Msg,From,#dp{mors = master} = P) ->	
	case actordb_sqlprocutil:has_schema_updated(P,[]) of
		ok ->
			case P#dp.netchanges == actordb_local:net_changes() of
				false ->
					?DBG("Running re-election before read"),
					{noreply,actordb_sqlprocutil:start_verify(P#dp{callqueue = queue:in({From,{read,Msg}},P#dp.callqueue)},false)};
				true ->
					case Msg of	
						{Mod,Func,Args} ->
							case apply(Mod,Func,[P#dp.cbstate|Args]) of
								{reply,What,Sql,NS} ->
									{reply,{What,actordb_sqlite:exec(P#dp.db,Sql,read)},P#dp{cbstate = NS}};
								{reply,What,NS} ->
									{reply,What,P#dp{cbstate = NS}};
								{reply,What} ->
									{reply,What,P};
								{Sql,State} ->
									{reply,actordb_sqlite:exec(P#dp.db,Sql,read),P#dp{cbstate = State}};
								Sql ->
									{reply,actordb_sqlite:exec(P#dp.db,Sql,read),P}
							end;
						{Sql,{Mod,Func,Args}} ->
							case apply(Mod,Func,[P#dp.cbstate,actordb_sqlite:exec(P#dp.db,Sql,read)|Args]) of
								{write,Write} ->
									case Write of
										_ when is_binary(Write); is_list(Write) ->
											write_call(#write{sql = iolist_to_binary(Write)},From,P);
										{_,_,_} ->
											write_call(#write{mfa = Write},From,P)
									end;
								{write,Write,NS} ->
									case Write of
										_ when is_binary(Write); is_list(Write) ->
											write_call(#write{sql = iolist_to_binary(Write)},
													   From,P#dp{cbstate = NS});
										{_,_,_} ->
											write_call(#write{mfa = Write},From,P#dp{cbstate = NS})
									end;
								{reply,What,NS} ->
									{reply,What,P#dp{cbstate = NS}};
								{reply,What} ->
									{reply,What,P}
							end;
						Sql ->
							{reply,actordb_sqlite:exec(P#dp.db,Sql,read),P}
					end
			end;
		% Schema has changed. Execute write on schema update.
		% Place this read in callqueue for later execution.
		{NewVers,Sql1} ->
			write_call1(#write{sql = Sql1},undefined,NewVers, P#dp{callqueue = queue:in({From,{read,Msg}},P#dp.callqueue)})
	end;
read_call(_Msg,_From,P) ->
	?DBG("redirect read ~p",[P#dp.masternode]),
	actordb_sqlprocutil:redirect_master(P).


write_call(#write{mfa = MFA, sql = Sql, transaction = Transaction} = Msg,From,P) ->
	?DBG("writecall evnum_prewrite=~p, writeinfo=~p",[P#dp.evnum,{MFA,Sql,Transaction}]),
	case actordb_sqlprocutil:has_schema_updated(P,Sql) of
		{NewVers,Sql1} ->
			% First update schema, then do the transaction.
			write_call1(#write{sql = Sql1},undefined,NewVers, P#dp{callqueue = queue:in({From,Msg},P#dp.callqueue)});
		ok when MFA == undefined ->
			write_call1(Msg,From,P#dp.schemavers,P);
		_ ->
			{Mod,Func,Args} = MFA,
			case apply(Mod,Func,[P#dp.cbstate|Args]) of
				{reply,What,OutSql,NS} ->
					reply(From,What),
					write_call1(#write{sql = OutSql, transaction = Transaction},undefined,P#dp.schemavers,P#dp{cbstate = NS});
				{reply,What,NS} ->
					{reply,What,P#dp{cbstate = NS}};
				{reply,What} ->
					{reply,What,P};
				{OutSql,State} ->
					write_call1(#write{sql = OutSql,transaction = Transaction},From,P#dp.schemavers,P#dp{cbstate = State});
				OutSql ->
					write_call1(#write{sql = OutSql,transaction = Transaction},From,P#dp.schemavers,P)
			end
	end.
% Not a multiactor transaction write
write_call1(#write{sql = Sql,transaction = undefined} = W,From,NewVers,P) ->
	EvNum = P#dp.evnum+1,
	case Sql of
		delete ->
			actordb_sqlprocutil:delete_actor(P),
			reply(From,ok),
			?DBG("Write delete"),
			{stop,normal,P#dp{db = undefined}};
		{moved,MovedTo} ->
			actordb_sqlprocutil:delete_actor(P#dp{movedtonode = MovedTo}),
			reply(From,ok),
			?DBG("Write moved"),
			{stop,normal,P#dp{db = undefined}};
		_ ->
			ComplSql = 
					[<<"$SAVEPOINT 'adb';">>,
					 actordb_sqlprocutil:semicolon(Sql),
					 <<"$UPDATE __adb SET val='">>,butil:tobin(EvNum),<<"' WHERE id=">>,?EVNUM,";",
					 <<"$UPDATE __adb SET val='">>,butil:tobin(P#dp.current_term),<<"' WHERE id=">>,?EVTERM,";",
					 <<"$RELEASE SAVEPOINT 'adb';">>
					 ],
			case P#dp.flags band ?FLAG_SEND_DB > 0 of
				true ->
					VarHeader = actordb_sqlprocutil:create_var_header_with_db(P);
				_ ->
					VarHeader = actordb_sqlprocutil:create_var_header(P)
			end,
			case W#write.records of
				[_|_] ->
					Res = actordb_sqlite:exec(P#dp.db,ComplSql,W#write.records,P#dp.current_term,EvNum,VarHeader);
				_ ->
					Res = actordb_sqlite:exec(P#dp.db,ComplSql,P#dp.current_term,EvNum,VarHeader)
			end,
			case actordb_sqlite:okornot(Res) of
				ok ->
					?DBG("Write result ~p, repl_status ~p",[Res,esqlite3:replicate_status(P#dp.db)]),
					case ok of
						_ when P#dp.follower_indexes == [] ->
							{noreply,actordb_sqlprocutil:reply_maybe(
										P#dp{callfrom = From, callres = Res,evnum = EvNum, flags = P#dp.flags band (bnot ?FLAG_SEND_DB),
												netchanges = actordb_local:net_changes(),
												schemavers = NewVers,evterm = P#dp.current_term},1,[])};
						_ ->
							% reply on appendentries response or later if nodes are behind.
							{noreply, ae_timer(P#dp{callfrom = From, callres = Res, flags = P#dp.flags band (bnot ?FLAG_SEND_DB),
											follower_indexes = update_followers(EvNum,P#dp.follower_indexes),
											netchanges = actordb_local:net_changes(),
										evterm = P#dp.current_term, evnum = EvNum,schemavers = NewVers})}
					end;
				Resp ->
					actordb_sqlite:exec(P#dp.db,<<"ROLLBACK;">>),
					reply(From,Resp),
					{noreply,P}
			end
	end;
write_call1(#write{sql = Sql1, transaction = {Tid,Updaterid,Node} = TransactionId},From,NewVers,P) ->
	{_CheckPid,CheckRef} = actordb_sqlprocutil:start_transaction_checker(Tid,Updaterid,Node),
	?DBG("Starting transaction write id ~p, curtr ~p, sql ~p",
				[TransactionId,P#dp.transactionid,Sql1]),
	case P#dp.follower_indexes of
		[] ->
			% If single node cluster, no need to store sql first.
			case P#dp.transactionid of
				TransactionId ->
					% Transaction can write to single actor more than once (especially for KV stores)
					% if we are already in this transaction, just update sql.
					{_OldSql,EvNum,_} = P#dp.transactioninfo,
					case Sql1 of
						delete ->
							ComplSql = <<"delete">>,
							Res = ok;
						_ ->
							ComplSql = Sql1,
							Res = actordb_sqlite:exec(P#dp.db,ComplSql,write)
					end;
				undefined ->
					EvNum = P#dp.evnum+1,
					case Sql1 of
						delete ->
							Res = ok,
							ComplSql = <<"delete">>;
						_ ->
							ComplSql = 
								[<<"$SAVEPOINT 'adb';">>,
								 actordb_sqlprocutil:semicolon(Sql1),
								 <<"$UPDATE __adb SET val='">>,butil:tobin(EvNum),<<"' WHERE id=">>,?EVNUM,";",
								 <<"$UPDATE __adb SET val='">>,butil:tobin(P#dp.current_term),<<"' WHERE id=">>,?EVTERM,";"
								 ],
							Res = actordb_sqlite:exec(P#dp.db,ComplSql,write)
					end
			end,
			case actordb_sqlite:okornot(Res) of
				ok ->
					?DBG("Transaction ok"),
					{noreply, actordb_sqlprocutil:reply_maybe(P#dp{transactionid = TransactionId, 
								evterm = P#dp.current_term,
								transactioncheckref = CheckRef,
								transactioninfo = {ComplSql,EvNum,NewVers}, callfrom = From, callres = Res},1,[])};
				_Err ->
					ok = actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,<<"ROLLBACK;">>)),
					erlang:demonitor(CheckRef),
					?DBG("Transaction not ok ~p",[_Err]),
					{reply,Res,P#dp{activity = make_ref(), transactionid = undefined, evterm = P#dp.current_term}}
			end;
		_ ->
			EvNum = P#dp.evnum+1,
			case P#dp.transactionid of
				TransactionId when Sql1 /= delete ->
					% Rollback prev version of sql.
					ok = actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,<<"ROLLBACK;">>)),
					{OldSql,_EvNum,_} = P#dp.transactioninfo,
					% Combine prev sql with new one.
					Sql = iolist_to_binary([OldSql,Sql1]),
					TransactionInfo = [<<"$INSERT OR REPLACE INTO __transactions ",
										 "(id,tid,updater,node,schemavers,sql) VALUES (1,">>,
											(butil:tobin(Tid)),",",(butil:tobin(Updaterid)),",'",Node,"',",
								 				(butil:tobin(NewVers)),",",
								 				"'",(base64:encode(Sql)),"');"];
				TransactionId ->
					Sql = <<"delete">>,
					% First store transaction info. Then run actual sql of transaction.
					TransactionInfo = [<<"$INSERT OR REPLACE INTO __transactions (id,tid,updater,node,schemavers,sql) VALUES (1,">>,
											(butil:tobin(Tid)),",",(butil:tobin(Updaterid)),",'",Node,"',",
											(butil:tobin(NewVers)),",",
								 				"'",(base64:encode(Sql)),"');"];
				_ ->
					case Sql1 of
						delete ->
							Sql = <<"delete">>;
						_ ->
							Sql = iolist_to_binary(Sql1)
					end,
					% First store transaction info. Then run actual sql of transaction.
					TransactionInfo = [<<"$INSERT INTO __transactions (id,tid,updater,node,schemavers,sql) VALUES (1,">>,
											(butil:tobin(Tid)),",",(butil:tobin(Updaterid)),",'",Node,"',",
											(butil:tobin(NewVers)),",",
								 				"'",(base64:encode(Sql)),"');"]
			end,
			ComplSql = 
					[<<"$SAVEPOINT 'adb';">>,
					 TransactionInfo,
					 <<"$UPDATE __adb SET val='">>,butil:tobin(EvNum),<<"' WHERE id=">>,?EVNUM,";",
					 <<"$UPDATE __adb SET val='">>,butil:tobin(P#dp.current_term),<<"' WHERE id=">>,?EVTERM,";",
					 <<"$RELEASE SAVEPOINT 'adb';">>
					 ],
			VarHeader = actordb_sqlprocutil:create_var_header(P),
			ok = actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,ComplSql,P#dp.current_term,EvNum,VarHeader)),
			{noreply,ae_timer(P#dp{callfrom = From,callres = undefined, evterm = P#dp.current_term,evnum = EvNum,
						  transactioninfo = {Sql,EvNum+1,NewVers},
						  follower_indexes = update_followers(EvNum,P#dp.follower_indexes),
						  transactioncheckref = CheckRef,
						  transactionid = TransactionId})}
	end.

update_followers(_Evnum,L) ->
	Ref = make_ref(),
	[begin
		F#flw{wait_for_response_since = Ref, call_count = F#flw.call_count+1}
	end || F <- L].




handle_cast({diepls,Reason},P) ->
	{noreply,P};
	% ?DBG("diepls ~p ~p",[P#dp.mors,Reason]),
	% case Reason of
	% 	nomaster when P#dp.mors == slave ->
	% 		{stop,normal,P};
	% 	_ ->
	% 		case handle_info(check_inactivity,P) of
	% 			{noreply,_,hibernate} ->
	% 				?DBG("req die ~p ~p ~p",[P#dp.actorname,P#dp.actortype,Reason]),
	% 				{stop,normal,P};
	% 			R ->
	% 				R
	% 		end
	% end;
handle_cast(print_info,P) ->
	?AINF("~p~n",[?R2P(P)]),
	{noreply,P};
handle_cast(Msg,#dp{mors = master, verified = true} = P) ->
	case apply(P#dp.cbmod,cb_cast,[Msg,P#dp.cbstate]) of
		{noreply,S} ->
			{noreply,P#dp{cbstate = S}};
		noreply ->
			{noreply,P}
	end;
handle_cast(_Msg,P) ->
	?INF("sqlproc ~p unhandled cast ~p~n",[P#dp.cbmod,_Msg]),
	{noreply,P}.


handle_info(doqueue, P) ->
	{noreply,actordb_sqlprocutil:doqueue(P)};
handle_info({'DOWN',Monitor,_,PID,Reason},P) ->
	down_info(PID,Monitor,Reason,P);
handle_info(ae_timer,P) ->
	case P#dp.mors == master andalso P#dp.verified == true of
		true ->
			case actordb_sqlprocutil:resend_ae(P,0,P#dp.follower_indexes,[]) of
				{0,_} ->
					?DBG("AE timer stop, evnum=~p, evterm=~p followers=~p",[P#dp.evnum,P#dp.evterm,P#dp.follower_indexes]),
					{noreply,P#dp{resend_ae_timer = undefined}};
				{_,NF} ->
					?DBG("AE timer continue"),
					T = erlang:send_after(1000,self(),ae_timer),
					{noreply,P#dp{follower_indexes = NF, resend_ae_timer = T}}
			end;
		false ->
			{noreply, P}
	end;
handle_info(doelection,P) ->
	Empty = queue:is_empty(P#dp.callqueue),
	case ok of
		_ when Empty; is_pid(P#dp.election); P#dp.masternode /= undefined; 
					P#dp.flags band ?FLAG_NO_ELECTION_TIMEOUT > 0 ->
			case P#dp.masternode /= undefined andalso P#dp.masternode /= actordb_conf:node_name() andalso 
					bkdcore_rpc:is_connected(P#dp.masternode) of
				true ->
					?DBG("Election ignore, master=~p",[P#dp.masternode]),
					{noreply,P};
				false ->
					?DBG("Election timeout, master=~p, election=~p, empty=~p, me=~p",
						[P#dp.masternode,P#dp.election,Empty,actordb_conf:node_name()]),
					{noreply,actordb_sqlprocutil:start_verify(P#dp{election = undefined},false)}
			end;
		_ ->
			?DBG("Election timeout"),
			{noreply,actordb_sqlprocutil:start_verify(P#dp{election = undefined},false)}
	end;
handle_info(retry_copy,P) ->
	case P#dp.mors == master andalso P#dp.verified == true of
		true ->
			{noreply,actordb_sqlprocutil:retry_copy(P)};
		_ ->
			{noreply, P}
	end;
handle_info(check_locks,P) ->
	case P#dp.locked of
		[] ->
			{noreply,P};
		_ ->
			erlang:send_after(1000,self(),check_locks),
			{noreply, actordb_sqlprocutil:check_locks(P,P#dp.locked,[])}
	end;
handle_info(do_checkpoint,P) ->
	case P#dp.locked of
		[ae] ->
			erlang:send_after(100,self(),do_checkpoint);
		_ ->
			actordb_sqlprocutil:do_checkpoint(P)
	end,
	{noreply,P};
% handle_info({inactivity_timer,N},P) ->
% 	handle_info({check_inactivity,N},P#dp{timerref = {undefined,N}});
% handle_info({check_inactivity,N}, P) ->
% 	case check_inactivity(N,P) of
% 		{noreply, NP} ->
% 			{noreply,doqueue(NP)};
% 		R ->
% 			R
% 	end;
% handle_info(check_inactivity, P) ->
% 	handle_info({check_inactivity,10},P);
handle_info(stop,P) ->
	?DBG("Received stop msg"),
	handle_info({stop,normal},P);
handle_info({stop,Reason},P) ->
	?DBG("Actor stop with reason ~p",[Reason]),
	{stop, normal, P};
handle_info(print_info,P) ->
	handle_cast(print_info,P);
handle_info(commit_transaction,P) ->
	down_info(0,12345,done,P#dp{transactioncheckref = 12345});
handle_info(start_copy,P) ->
	?DBG("Start copy ~p",[P#dp.copyfrom]),
	case P#dp.copyfrom of
		{move,NewShard,Node} ->
			OldActor = P#dp.actorname,
			Msg = {move,NewShard,actordb_conf:node_name(),P#dp.copyreset,P#dp.cbstate};
		{split,MFA,Node,OldActor,NewActor} ->
			% Change node to this node, so that other actor knows where to send db.
			Msg = {split,MFA,actordb_conf:node_name(),OldActor,NewActor,P#dp.copyreset,P#dp.cbstate};
		{Node,OldActor} ->
			Msg = {copy,{actordb_conf:node_name(),OldActor,P#dp.actorname}}
	end,
	Home = self(),
	spawn(fun() ->
		case actordb:rpc(Node,OldActor,{?MODULE,call,[{OldActor,P#dp.actortype},[],Msg,P#dp.cbmod,onlylocal]}) of
			ok ->
				ok;
			{ok,_} ->
				ok;
			{redirect,_} ->
				Home ! start_copy_done;
			Err ->
				?ERR("Unable to start copy from ~p, ~p",[P#dp.copyfrom,Err]),
				Home ! {stop,Err}
		end
	end),
	{noreply,P};
handle_info(start_copy_done,P) ->
	{ok,NP} = init(P,copy_done),
	{noreply,NP};
handle_info(Msg,#dp{verified = true} = P) ->
	case apply(P#dp.cbmod,cb_info,[Msg,P#dp.cbstate]) of
		{noreply,S} ->
			{noreply,P#dp{cbstate = S}};
		noreply ->
			{noreply,P}
	end;
handle_info(_Msg,P) ->
	?DBG("sqlproc ~p unhandled info ~p~n",[P#dp.cbmod,_Msg]),
	{noreply,P}.

% check_inactivity(NTimer,#dp{mors = master} = P) ->
% 	case P#dp.mors of
% 		master ->
% 			% If we have been waiting for response for an unreasonable amount of time (600ms),
% 			%  call appendentries_start on node. If received node will call back appendentries_response.
% 			{NResponsesWaiting,Followers} = resend(P,0,P#dp.follower_indexes,[]);
% 		_ ->
% 			NResponsesWaiting = 0,
% 			Followers = P#dp.follower_indexes
% 	end,
% 	check_inactivity(NTimer,P#dp{follower_indexes = Followers},NResponsesWaiting);
% check_inactivity(NTimer,P) ->
% 	check_inactivity(NTimer,P,0).

% check_inactivity(_NTimer,P,NResponsesWaiting) ->
% 	% ?INF("check inactivity"),
% 	Empty = queue:is_empty(P#dp.callqueue),
% 	Age = actordb_local:min_ref_age(P#dp.activity),
% 	case P of
% 		#dp{callfrom = undefined, verified = true, transactionid = undefined,dbcopyref = undefined,
% 			 dbcopy_to = [], locked = [], copyproc = undefined, copylater = undefined} when Empty, Age >= 1000, NResponsesWaiting == 0 ->
		
% 			case P#dp.movedtonode of
% 				undefined ->
% 					case apply(P#dp.cbmod,cb_candie,[P#dp.mors,P#dp.actorname,P#dp.actortype,P#dp.cbstate]) of
% 						true ->
% 							?DBG("Die because temporary ~p ~p master ~p",[P#dp.actorname,P#dp.actortype,P#dp.masternode]),
% 							{stop,normal,P};
% 						never ->
% 							{noreply,check_timer(P)};
% 						false ->
% 							case P#dp.timerref of
% 								{undefined,_} ->
% 									Timer = P#dp.timerref;
% 								{TimerRef,_} ->
% 									erlang:cancel_timer(TimerRef),
% 									Timer = {undefined,element(2,P#dp.timerref)}
% 							end,
% 							{noreply,P#dp{timerref = Timer},hibernate}
% 					end;
% 				_ when Age >= 5000 ->
% 					case apply(P#dp.cbmod,cb_candie,[P#dp.mors,P#dp.actorname,P#dp.actortype,P#dp.cbstate]) of
% 						never ->
% 							{noreply,check_timer(P)};
% 						_ ->
% 							{stop,normal,P}
% 					end;
% 				_ ->
% 					Now = actordb_local:actor_activity(P#dp.activity_now),
% 					{noreply,check_timer(P#dp{activity_now = Now})}
% 			end;
		% _ when Empty == false, P#dp.verified == false, NTimer > 1, is_tuple(P#dp.election) ->
		% 	case timer:now_diff(os:timestamp(),P#dp.election) > 500000 of
		% 		true ->
		% 			?INF("Restarting election due to timeout"),
		% 			{noreply, check_timer(actordb_sqlprocutil:start_verify(P,false))};
		% 		false ->
		% 			{noreply, check_timer(P)}
		% 	end;
		% _ ->
		% 	Now = actordb_local:actor_activity(P#dp.activity_now),
			% case P#dp.mors of
			% 	master when P#dp.db /= undefined ->
			% 		{_,NPages} = actordb_sqlite:wal_pages(P#dp.db),
			% 		DbSize = NPages*(?PAGESIZE+40),
			% 		case DbSize > 1024*1024 andalso P#dp.dbcopyref == undefined andalso P#dp.dbcopy_to == [] of
			% 			true ->
			% 				NotSynced = lists:foldl(fun(F,Count) ->
			% 					case F#flw.match_index /= P#dp.evnum of
			% 						true ->
			% 							Count+1;
			% 						false ->
			% 							Count
			% 					end 
			% 				end,0,P#dp.follower_indexes),
			% 				case NotSynced of
			% 					0 ->
			% 						WalFrom = actordb_sqlprocutil:do_checkpoint(P);
			% 					% If nodes arent synced, tolerate 30MB of wal size.
			% 					_ when DbSize >= 1024*1024*30 ->
			% 						WalFrom = actordb_sqlprocutil:do_checkpoint(P);
			% 					_ ->
			% 						WalFrom = P#dp.wal_from
			% 				end;
			% 			false ->
			% 				WalFrom = P#dp.wal_from
			% 		end;
			% 	_ ->
			% 		WalFrom = P#dp.wal_from
			% end,
			% {noreply,check_timer(retry_copy(P#dp{activity_now = Now, %wal_from = WalFrom,
			% 									locked = abandon_locks(P,P#dp.locked,[])}))}
	% 		{noreply,check_timer(P#dp{activity_now = Now})}
	% end.



down_info(PID,_Ref,Reason,#dp{election = PID} = P1) ->
	case Reason of
		noproc ->
			{noreply, P1#dp{election = actordb_sqlprocutil:election_timer(undefined)}};
		{failed,Err} ->
			P = P1,
			?ERR("Election failed, retrying later ~p",[Err]),
			{noreply, P#dp{election = actordb_sqlprocutil:election_timer(undefined)}};
		% We are leader, evnum == 0, which means no other node has any data.
		% If create flag not set stop.
		{leader,_,_} when (P1#dp.flags band ?FLAG_CREATE) == 0, P1#dp.schemavers == undefined ->
			P = P1,
			?INF("Stopping with nocreate ",[]),
			{stop,nocreate,P1};
		{leader,NewFollowers,AllSynced} ->
			actordb_local:actor_mors(master,actordb_conf:node_name()),
			P = actordb_sqlprocutil:reopen_db(P1#dp{mors = master, election = undefined, 
													flags = P1#dp.flags band (bnot ?FLAG_WAIT_ELECTION),
													locked = lists:delete(ae,P1#dp.locked)}),
			ReplType = apply(P#dp.cbmod,cb_replicate_type,[P#dp.cbstate]),
			?DBG("Elected leader term=~p, nodes_synced=~p",[P1#dp.current_term,AllSynced]),
			ok = esqlite3:replicate_opts(P#dp.db,term_to_binary({P#dp.cbmod,P#dp.actorname,P#dp.actortype,P#dp.current_term}),ReplType),

			case P#dp.schemavers of
				undefined ->
					Transaction = [],
					Rows = [];
				_ ->
					case actordb_sqlite:exec(P#dp.db,
							<<"SELECT * FROM __adb;",
							  "SELECT * FROM __transactions;">>,read) of
						{ok,[[{columns,_},{rows,Transaction}],
						     [{columns,_},{rows,Rows}]]} ->
						     	ok;
						Err ->
							?ERR("Unable read from db for, error=~p after election.",[Err]),
							Transaction = Rows = [],
							exit(error)
					end
			end,
			
			case butil:ds_val(?COPYFROMI,Rows) of
				CopyFrom1 when byte_size(CopyFrom1) > 0 ->
					{CopyFrom,CopyReset,CbState} = binary_to_term(base64:decode(CopyFrom1));
				_ ->
					CopyFrom = CopyReset = undefined,
					CbState = P#dp.cbstate
			end,
			% After election is won a write needs to be executed. What we will write depends on the situation:
			%  - If this actor has been moving, do a write to clean up after it (or restart it)
			%  - If transaction active continue with write.
			%  - If empty db or schema not up to date create/update it.
			%  - It can also happen that both transaction active and actor move is active. Sqls will be combined.
			%  - Otherwise just empty sql, which still means an increment for evnum and evterm in __adb.
			{NP,Sql,Callfrom} = actordb_sqlprocutil:post_election_sql(P#dp{verified = true,copyreset = CopyReset, 
																			cbstate = CbState},
																		Transaction,CopyFrom,[],undefined),
			case P#dp.callres of
				undefined ->
					% If nothing to store and all nodes synced, send an empty AE.
					case is_atom(Sql) == false andalso iolist_size(Sql) == 0 of
						true when AllSynced, NewFollowers == [] ->
							{noreply,actordb_sqlprocutil:doqueue(NP#dp{follower_indexes = NewFollowers,
														netchanges = actordb_local:net_changes()})};
						true when AllSynced ->
							?DBG("Nodes synced, running empty AE."),
							NewFollowers1 = [actordb_sqlprocutil:send_empty_ae(P,NF) || NF <- NewFollowers],
							{noreply,ae_timer(NP#dp{callres = ok,follower_indexes = NewFollowers1,
														netchanges = actordb_local:net_changes()})};
						_ ->
							?DBG("Running post election write on nodes ~p, withdb ~p",
									[P#dp.follower_indexes,NP#dp.flags band ?FLAG_SEND_DB > 0]),
							% it must always return noreply
							write_call(#write{sql = Sql, transaction = NP#dp.transactionid},Callfrom, NP)
					end;
				_ ->
					?DBG("Delaying election write callres=~p, followers=~p",[P#dp.callres,P#dp.follower_indexes]),
					{noreply,NP#dp{callqueue = queue:in_r({Callfrom,#write{sql = Sql,transaction = NP#dp.transactionid}},
															P#dp.callqueue)}}
			end;
		follower ->
			{noreply,actordb_sqlprocutil:reopen_db(P1#dp{election = actordb_sqlprocutil:election_timer(P1#dp.election), 
															masternode = undefined, mors = slave})}
	end;
down_info(_PID,Ref,Reason,#dp{transactioncheckref = Ref} = P) ->
	?DBG("Transactioncheck died ~p myid ~p",[Reason,P#dp.transactionid]),
	case P#dp.transactionid of
		{Tid,Updaterid,Node} ->
			case Reason of
				noproc ->
					{_CheckPid,CheckRef} = actordb_sqlprocutil:start_transaction_checker(Tid,Updaterid,Node),
					{noreply,P#dp{transactioncheckref = CheckRef}};
				abandoned ->
					case handle_call({commit,false,P#dp.transactionid},undefined,P#dp{transactioncheckref = undefined}) of
						{stop,normal,NP} ->
							{stop,normal,NP};
						{reply,_,NP} ->
							{noreply,NP};
						{noreply,NP} ->
							{noreply,NP}
					end;
				done ->
					case handle_call({commit,true,P#dp.transactionid},undefined,P#dp{transactioncheckref = undefined}) of
						{stop,normal,NP} ->
							{stop,normal,NP};
						{reply,_,NP} ->
							{noreply,NP};
						{noreply,NP} ->
							{noreply,NP}
					end
			end;
		_ ->
			{noreply,P#dp{transactioncheckref = undefined}}
	end;
down_info(PID,_Ref,Reason,#dp{copyproc = PID} = P) ->
	?DBG("copyproc died ~p my_status=~p copyfrom=~p",[Reason,P#dp.mors,P#dp.copyfrom]),
	case Reason of
		unlock -> %when P#dp.mors == master; is_binary(P#dp.copyfrom) ->
			case catch actordb_sqlprocutil:callback_unlock(P) of
				ok ->
					{ok,NP} = init(P,copyproc_done),
					{noreply,NP};
				Err ->
					?DBG("Unable to unlock"),
					{stop,Err,P}
			end;
		ok when P#dp.mors == slave ->
			?DBG("Stopping because slave"),
			{stop,normal,P};
		nomajority ->
			{stop,{error,nomajority},P};
		% Error copying. 
		%  - There is a chance copy succeeded. If this node was able to send unlock msg
		%    but connection was interrupted before replying. If this is the case next read/write call will start
		%    actor on this node again and everything will be fine.
		%  - If copy failed before unlock, then it actually did fail. In that case move will restart 
		%    eventually.
		_ ->
			?ERR("Coproc died with error ~p~n",[Reason]),
			actordb_sqlprocutil:empty_queue(P#dp.callqueue,{error,copyfailed}),
			{stop,Reason,P}
	end;
down_info(PID,_Ref,Reason,P) ->
	case lists:keyfind(PID,#cpto.pid,P#dp.dbcopy_to) of
		false ->
			?DBG("downmsg, verify maybe? ~p",[P#dp.election]),
			case apply(P#dp.cbmod,cb_info,[{'DOWN',_Ref,process,PID,Reason},P#dp.cbstate]) of
				{noreply,S} ->
					{noreply,P#dp{cbstate = S}};
				noreply ->
					{noreply,P}
			end;
		C ->
			?DBG("Down copyto proc ~p ~p ~p ~p ~p",[P#dp.actorname,Reason,C#cpto.ref,P#dp.locked,P#dp.dbcopy_to]),
			case Reason of
				ok ->
					ok;
				_ ->
					?ERR("Copyto process invalid exit ~p",[Reason])
			end,
			WithoutCopy = lists:keydelete(PID,#lck.pid,P#dp.locked),
			NewCopyto = lists:keydelete(PID,#cpto.pid,P#dp.dbcopy_to),
			false = lists:keyfind(C#cpto.ref,2,WithoutCopy),
			% wait_copy not in list add it (2nd stage of lock)
			WithoutCopy1 =  [#lck{ref = C#cpto.ref, ismove = C#cpto.ismove,node = C#cpto.node,time = os:timestamp(),
									actorname = C#cpto.actorname}|WithoutCopy],
			erlang:send_after(1000,self(),check_locks),
			NP = P#dp{dbcopy_to = NewCopyto, 
						locked = WithoutCopy1,
						activity = make_ref()},
			case queue:is_empty(P#dp.callqueue) of
				true ->
					{noreply,NP};
				false ->
					handle_info(doqueue,NP)
			end
	end.


terminate(Reason, P) ->
	?DBG("Terminating ~p",[Reason]),
	actordb_sqlite:stop(P#dp.db),
	distreg:unreg(self()),
	ok.
code_change(_, P, _) ->
	{ok, P}.
init(#dp{} = P,_Why) ->
	% ?DBG("Reinit because ~p, ~p, ~p",[_Why,?R2P(P),get()]),
	?DBG("Reinit because ~p",[_Why]),
	actordb_sqlite:stop(P#dp.db),
	% cancel_timer(P),
	Flags = P#dp.flags band (bnot ?FLAG_WAIT_ELECTION) band (bnot ?FLAG_STARTLOCK),
	case ok of
		_ when is_reference(P#dp.election) ->
			erlang:cancel_timer(P#dp.election);
		_ when is_pid(P#dp.election) ->
			exit(P#dp.election,reinit);
		_ ->
		 	ok
	end,
	init([{actor,P#dp.actorname},{type,P#dp.actortype},{mod,P#dp.cbmod},{flags,Flags},
		  {state,P#dp.cbstate},{slave,P#dp.mors == slave},{queue,P#dp.callqueue},{startreason,{reinit,_Why}}]).
% Never call other processes from init. It may cause deadlocks. Whoever
% started actor is blocking waiting for init to finish.
init([_|_] = Opts) ->
	% put(opt,Opts),
	% Random needs to be unique per-node, not per-actor. 
	random:seed(actordb_conf:cfgtime()),
	case actordb_sqlprocutil:parse_opts(check_timer(#dp{mors = master, callqueue = queue:new(), 
									schemanum = catch actordb_schema:num()}),Opts) of
		{registered,Pid} ->
			explain({registered,Pid},Opts),
			{stop,normal};
		P when (P#dp.flags band ?FLAG_ACTORNUM) > 0 ->
			explain({actornum,P#dp.dbpath,actordb_sqlprocutil:read_num(P)},Opts),
			{stop,normal};
		P when (P#dp.flags band ?FLAG_EXISTS) > 0 ->
			{ok,_Db,SchemaTables,_PageSize} = actordb_sqlite:init(P#dp.dbpath,wal),
			explain({ok,[{columns,{<<"exists">>}},{rows,[{butil:tobin(SchemaTables /= [])}]}]},Opts),
			{stop,normal};
		P when (P#dp.flags band ?FLAG_STARTLOCK) > 0 ->
			case lists:keyfind(lockinfo,1,Opts) of
				{lockinfo,dbcopy,{Ref,CbState,CpFrom,CpReset}} ->
					?DBG("Starting actor slave lock for copy on ref ~p",[Ref]),
					{ok,Pid} = actordb_sqlprocutil:start_copyrec(P#dp{mors = slave, cbstate = CbState, 
													dbcopyref = Ref,  copyfrom = CpFrom, copyreset = CpReset}),
					{ok,P#dp{copyproc = Pid, verified = false,mors = slave, copyfrom = P#dp.copyfrom}};
				{lockinfo,wait} ->
					% {ok,cancel_timer(P)}
					{ok,P}
			end;
		P when P#dp.copyfrom == undefined ->
			?DBG("Actor start, copy=~p, flags=~p, mors=~p startreason=~p",[P#dp.copyfrom,
							P#dp.flags,P#dp.mors,butil:ds_val(startreason,Opts)]),
			% Could be normal start after moving to another node though.
			MovedToNode = apply(P#dp.cbmod,cb_checkmoved,[P#dp.actorname,P#dp.actortype]),
			RightCluster = lists:member(MovedToNode,bkdcore:all_cluster_nodes()),
			case butil:readtermfile([P#dp.dbpath,"-term"]) of
				{VotedFor,VotedCurrentTerm,VoteEvnum,VoteEvTerm} ->
					ok;
				_ ->
					VotedFor = undefined,
					VoteEvnum = VotedCurrentTerm = VoteEvTerm = 0
			end,
			case ok of
				_ when P#dp.mors == slave ->
					% Read evnum and evterm from wal file if it exists
					case file:open([P#dp.dbpath,"-wal"],[read,binary,raw]) of
						{ok,F} ->
							case file:position(F,eof) of
								{ok,WalSize} when WalSize > 32+40+?PAGESIZE ->
									{ok,_} = file:position(F,{cur,-(?PAGESIZE+40)}),
									{ok,<<_:32,_:32,Evnum:64/big-unsigned,Evterm:64/big-unsigned>>} =
										file:read(F,24),
									file:close(F),
									?DBG("Actor start slave, with {Evnum,Evterm}=~p",[{Evnum,Evterm}]),
									{ok,P#dp{current_term = VotedCurrentTerm, voted_for = VotedFor, 
												% election = actordb_sqlprocutil:election_timer(undefined),
												evnum = Evnum, evterm = Evterm}};
								{ok,_} ->
									file:close(F),
									{ok,actordb_sqlprocutil:init_opendb(P#dp{current_term = VotedCurrentTerm,
													% election = actordb_sqlprocutil:election_timer(undefined),
													voted_for = VotedFor, evnum = VoteEvnum, evterm = VoteEvTerm})}
							end;
						{error,enoent} ->
							% {ok,P#dp{current_term = VotedCurrentTerm, voted_for = VotedFor, evnum = VoteEvum}}
							{ok,actordb_sqlprocutil:init_opendb(P#dp{current_term = VotedCurrentTerm,
										% election = actordb_sqlprocutil:election_timer(undefined),
										voted_for = VotedFor, evnum = VoteEvnum,evterm = VoteEvTerm})}
					end;
				_ when MovedToNode == undefined; RightCluster ->
					{ok,actordb_sqlprocutil:start_verify(actordb_sqlprocutil:init_opendb(
								P#dp{current_term = VotedCurrentTerm,voted_for = VotedFor, evnum = VoteEvnum,
										evterm = VoteEvTerm}),true)};
				_ ->
					?DBG("Actor moved ~p ~p ~p",[P#dp.actorname,P#dp.actortype,MovedToNode]),
					{ok, P#dp{verified = true, movedtonode = MovedToNode}}
			end;
		{stop,Explain} ->
			explain(Explain,Opts),
			{stop,normal};
		P ->
			self() ! start_copy,
			{ok,P#dp{mors = master}}
	end;
init(#dp{} = P) ->
	init(P,noreason).



explain(What,Opts) ->
	case lists:keyfind(start_from,1,Opts) of
		{_,{FromPid,FromRef}} ->
			FromPid ! {FromRef,What};
		_ ->
			ok
	end.

reply(undefined,_Msg) ->
	ok;
reply(From,Msg) ->
	gen_server:reply(From,Msg).

% cancel_timer(P) ->
% 	{Ref,_} = P#dp.timerref,
% 	case Ref /= undefined of
% 		true ->
% 			erlang:cancel_timer(Ref),
% 			P#dp{timerref = {undefined,0}};
% 		false ->
% 			P
% 	end.

ae_timer(P) ->
	case P#dp.resend_ae_timer of
		undefined ->
			P#dp{resend_ae_timer = erlang:send_after(1000,self(),ae_timer)};
		_ ->
			P
	end.

check_timer(P) ->
	P.
	% case P#dp.timerref of
	% 	{undefined,N} ->
	% 		Ref = erlang:send_after(1000,self(),{inactivity_timer,N+1}),
	% 		P#dp{timerref = {Ref,N}};
	% 	_ ->
	% 		P
	% end.

