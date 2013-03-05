%%% File    : erl_img.erl
%%% Author  : Tony Rogvall <tony@bix.hemma.se>
%%% Description : Image processing stuff
%%% Created :  5 Mar 2003 by Tony Rogvall <tony@bix.hemma.se>

-module(erl_img).

-include_lib("kernel/include/file.hrl").

-include_lib("erl_img.hrl").

-export([magic_info/1]).
-export([mime_type/1]).
-export([dir_info/1]).
-export([read_file_info/1]).
-export([read/2, write/2]).
-export([load/1, save/1, save/2, to_binary/1]).
-export([attribute/2, attribute/3, set_attribute/3]).
-export([extensions/1]).
-export([read_info/2]).
-export([write_info/3]).
-export([hex32/1, hex16/1, hex8/1]).
-export([crop/5, scale/2, scale/3]).

hex32(X) ->
    hex8(X bsr 24) ++ hex8(X bsr 16) ++ hex8(X bsr 8) ++ hex8(X).

hex16(X) ->
    hex8(X bsr 8) ++ hex8(X).

%% convert a hex byte into two ascii letters
hex8(X) ->
    [nib((X bsr 4) band 16#f),nib(X band 16#f)].

nib(N) when N =< 9 -> N+$0;
nib(N) -> (N-10)+$A.

%% Read magic info check MAGIC type and width and height (depth)
%% of image

%% Check a header of least 64 bytes
magic([Type|Ts], Bin) ->
    case apply(Type, magic, [Bin]) of
        true -> {true, Type };
        false -> magic(Ts, Bin)
    end;
magic([], _Bin) ->
    false.


%% Read file mtime information
file_info(File, _IMG) ->
    case file:read_file_info(File) of
        {ok, Info} when Info#file_info.type == regular,
                        Info#file_info.size > 0 ->
            {ok, {Info#file_info.mtime,Info#file_info.size}};
        {ok, _Other} ->
            {error, bad_file};
        Error ->
            Error
    end.



read_magic_info(Fd) ->
    file:position(Fd, 0),
    case file:read(Fd, 64) of
        {ok, Bin} ->
            case magic(?IMAGE_TYPES, Bin) of
                {true, Type} ->
                    read_info(Type, Fd);
                false ->
                    {error, not_supported}
            end;
        Error ->
            Error
    end.


magic_info(File) ->
    case file:open(File,[raw,binary,read]) of
        {ok,Fd} ->
            Res = read_magic_info(Fd),
            file:close(Fd),
            case Res of
                {ok,IMG} ->
                    {ok,IMG#erl_image { filename = File,
                                        name = filename:basename(File) }};
                Error ->
                    Error
            end;
        Error -> Error
    end.



mime_type(IMG) ->
    apply(IMG#erl_image.type, mime_type, []).

extensions(IMG) ->
    apply(IMG#erl_image.type, extensions, []).


read_file_info(File) ->
    case file_info(File,  #erl_image { }) of
        {ok, {MTime,Size}} ->
            case magic_info(File) of
                {ok,IMG} ->
                    {ok,IMG#erl_image { mtime = MTime,
                                        size = Size}};
                Error ->
                    Error
            end;
        Error  -> Error
    end.

load(Binary) when is_binary(Binary) ->
	load_opt(Binary, [ram, binary, read]);
load(File) ->
	load_opt(File, [raw, binary, read]).

load_opt(File, Opts) ->
    case file:open(File, Opts) of
        {ok,Fd} ->
            Res = case read_magic_info(Fd) of
                      {ok, IMG} ->
                          read(Fd, IMG#erl_image { filename = File });
                      Error ->
                          Error
                  end,
            file:close(Fd),
            Res;
        Error -> Error
    end.

save(IMG) ->
    save(IMG#erl_image.filename, IMG).

save(File, IMG) ->
    case file:open(File, [raw, binary, write]) of
        {ok,Fd} ->
            Res = write(Fd, IMG),
            file:close(Fd),
            Res;
        Error ->
            Error
    end.

to_binary(IMG) ->
    case file:open(<<>>, [ram, binary, write]) of
        {ok,Fd} ->
            ok = write(Fd, IMG),
            case ram_file:get_file_close(Fd) of
                {ok, Data} ->
                    {ok,Data};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

read_info(Type, Fd) ->
    file:position(Fd, 0),
    apply(Type, read_info, [Fd]).

write_info(Type, Fd, IMG) ->
    file:position(Fd, 0),
    apply(Type, write_info, [Fd,IMG]).

read(Fd,IMG) ->
    file:position(Fd, 0),
    apply(IMG#erl_image.type, read, [Fd,IMG]).

write(Fd,IMG) ->
    file:position(Fd, 0),
    apply(IMG#erl_image.type, write, [Fd,IMG]).



attribute(IMG, Key) ->
    {value, {_, Value}} = lists:keysearch(Key, 1, IMG#erl_image.attributes),
    Value.

attribute(IMG, Key, Default) ->
    case lists:keysearch(Key, 1, IMG#erl_image.attributes) of
        {value, {_, Value}} -> Value;
        false -> Default
    end.

set_attribute(IMG, Key, Value) ->
    As = IMG#erl_image.attributes,
    As1 = case lists:keysearch(Key, 1, As) of
              false -> [{Key,Value}|As];
              {value,_} ->
                  lists:keyreplace(Key, 1, As, {Key,Value})
          end,
    IMG#erl_image { attributes = As1 }.


dir_info(Dir) ->
    case file:list_dir(Dir) of
        {ok, Listing} ->
            dir_list(Listing,Dir);
        Error ->
            Error
    end.

dir_list([File|Fs], Dir) ->
    case read_file_info(filename:join(Dir, File)) of
        {ok,IMG} ->
            [IMG|dir_list(Fs, Dir)];
        _Error ->
            dir_list(Fs, Dir)
    end;
dir_list([], _Dir) ->
    [].


crop(#erl_image{ width = Width, height = Height } = IMG, Width, Height, 0, 0) ->
    IMG;
crop(IMG, Width, Height, XOffset, YOffset) when YOffset > 0 ->
    IMG1 = IMG#erl_image{ 
        pixmaps = lists:foldr(fun
                (PixMap, Acc) when PixMap#erl_pixmap.top + PixMap#erl_pixmap.height < YOffset ->
                    Acc;
                (PixMap, Acc) when PixMap#erl_pixmap.top >= YOffset ->
                    [PixMap#erl_pixmap{ top = PixMap#erl_pixmap.top - YOffset }|Acc];
                (PixMap, Acc) ->
                    [PixMap#erl_pixmap{ 
                            pixels = lists:map(fun({RowNum, Data}) ->
                                        {RowNum - YOffset, Data}
                                end, lists:nthtail(YOffset - PixMap#erl_pixmap.top, 
                                    lists:sort(fun({RowA, _}, {RowB, _}) ->
                                                RowA < RowB
                                        end, PixMap#erl_pixmap.pixels))),
                            height = PixMap#erl_pixmap.height - (YOffset - PixMap#erl_pixmap.top),
                            top = 0} | Acc]
            end, [], IMG#erl_image.pixmaps),
        height = IMG#erl_image.height - YOffset},
    crop(IMG1, Width, Height, XOffset, 0);
crop(IMG, Width, Height, XOffset, YOffset) when Height < IMG#erl_image.height ->
    IMG1 = IMG#erl_image{ 
        pixmaps = lists:foldr(fun
                (PixMap, Acc) when PixMap#erl_pixmap.top >= Height ->
                    Acc;
                (PixMap, Acc) when PixMap#erl_pixmap.top + PixMap#erl_pixmap.height =< Height ->
                    [PixMap|Acc];
                (PixMap, Acc) ->
                    [PixMap#erl_pixmap{ 
                            pixels = lists:sublist(lists:sort(fun({RowA, _}, {RowB, _}) ->
                                            RowA < RowB
                                    end, PixMap#erl_pixmap.pixels), 0, Height - PixMap#erl_pixmap.top),
                            height = Height - PixMap#erl_pixmap.top } | Acc]
            end, [], IMG#erl_image.pixmaps),
        height = Height},
    crop(IMG1, Width, Height, XOffset, YOffset);
crop(IMG, Width, Height, XOffset, YOffset) when XOffset > 0 ->
    IMG1 = IMG#erl_image{
        pixmaps = lists:foldr(fun
                (PixMap, Acc) when PixMap#erl_pixmap.left + PixMap#erl_pixmap.width < XOffset ->
                    Acc;
                (PixMap, Acc) when PixMap#erl_pixmap.left >= XOffset ->
                    [PixMap#erl_pixmap{ left = PixMap#erl_pixmap.left - XOffset }|Acc];
                (PixMap, Acc) ->
                    [PixMap#erl_pixmap{
                            pixels = lists:map(fun({RowNum, Data}) ->
                                        {RowNum, binary:part(Data, 
                                                IMG#erl_image.bytes_pp * XOffset, 
                                                byte_size(Data) - IMG#erl_image.bytes_pp * XOffset)}
                                end, PixMap#erl_pixmap.pixels),
                            width = PixMap#erl_pixmap.width - (XOffset - PixMap#erl_pixmap.left),
                            left = 0 } | Acc]
            end, [], IMG#erl_image.pixmaps),
        width = IMG#erl_image.width - XOffset},
    crop(IMG1, Width, Height, 0, YOffset);
crop(IMG, Width, Height, XOffset, YOffset) when Width < IMG#erl_image.width ->
    IMG1 = IMG#erl_image{
        pixmaps = lists:foldr(fun
                (PixMap, Acc) when PixMap#erl_pixmap.left >= Width ->
                    Acc;
                (PixMap, Acc) when PixMap#erl_pixmap.left + PixMap#erl_pixmap.width =< Width ->
                    [PixMap|Acc];
                (PixMap, Acc) ->
                    [PixMap#erl_pixmap{
                            pixels = lists:map(fun({_RowNum, Data}) ->
                                        binary:part(Data, 0, (Width - PixMap#erl_pixmap.left) * IMG#erl_image.bytes_pp)
                                end, PixMap#erl_pixmap.pixels),
                            width = Width - PixMap#erl_pixmap.left } | Acc]
            end, [], IMG#erl_image.pixmaps),
        width = Width},
    crop(IMG1, Width, Height, XOffset, YOffset).


interpolate_cubic(X, A, B, C, D) ->
    B + 0.5 * X * (C - A + X * (2*A - 5*B + 4*C - D + X * (3*(B-C) + D - A))).

interpolate_bicubic({X, Y}, {A1, B1, C1, D1}, {A2, B2, C2, D2}, {A3, B3, C3, D3}, {A4, B4, C4, D4}) ->
    interpolate_cubic(Y, 
        interpolate_cubic(X, A1, B1, C1, D1),
        interpolate_cubic(X, A2, B2, C2, D2),
        interpolate_cubic(X, A3, B3, C3, D3),
        interpolate_cubic(X, A4, B4, C4, D4)).

get_pixel_bytes(IMG, X, Y) ->
    lists:foldr(fun
            (PixMap, Pixel) when X < PixMap#erl_pixmap.left; 
                                 X >= PixMap#erl_pixmap.width + PixMap#erl_pixmap.left;
                                 Y < PixMap#erl_pixmap.top;
                                 Y >= PixMap#erl_pixmap.height + PixMap#erl_pixmap.top ->
                Pixel;
            (PixMap, _Pixel) ->
                {_, Data} = lists:nth(X - PixMap#erl_pixmap.left + 1,
                    lists:sort(fun({RowA, _}, {RowB, _}) ->
                                RowA < RowB
                        end, PixMap#erl_pixmap.pixels)),
                binary:part(Data, (Y - PixMap#erl_pixmap.top) * IMG#erl_image.bytes_pp, IMG#erl_image.bytes_pp)
        end, undefined, IMG#erl_image.pixmaps).

nearest_grid_points(Pos, Size) when Pos * Size =< 0.5 ->
    {0, 0, 0, 1};
nearest_grid_points(Pos, Size) when Pos * Size < 1.5 ->
    {0, 0, 1, 2};
nearest_grid_points(Pos, Size) when Pos * Size >= Size - 0.5 ->
    {Size - 2, Size - 1, Size - 1, Size - 1};
nearest_grid_points(Pos, Size) when Pos * Size > Size - 1.5 ->
    {Size - 3, Size - 2, Size - 1, Size - 1};
nearest_grid_points(Pos, Size) ->
    Trunc = trunc(Pos * Size - 0.5),
    {Trunc - 1, Trunc, Trunc + 1, Trunc + 2}.

clamp(Value, _Depth) when Value < 0 ->
    0;
clamp(Value, Depth) when Value > ((1 bsl Depth) - 1) ->
    (1 bsl Depth) - 1;
clamp(Value, _Depth) ->
    Value.

resample_pixels(IMG, NewWidth, NewHeight) ->
    Depth = IMG#erl_image.depth,
    % palettes not supported
    NumChannels = case IMG#erl_image.format of
        r8g8b8 -> 3;
        r8g8b8a8 -> 4;
        r16g16b16 -> 3;
        r16g16b16a16 -> 4;
        gray8 -> 1;
        gray16 -> 1;
        gray8a8 -> 2;
        gray8a16 -> 2
    end,

    BytesPerChannel = IMG#erl_image.bytes_pp div NumChannels,

    lists:map(fun(RowNum) ->
                YPos = (RowNum + 0.5) / NewHeight,
                {Ay, By, Cy, Dy} = nearest_grid_points(YPos, IMG#erl_image.height),
                RowPixels = lists:map(fun(ColNum) ->
                            XPos = (ColNum + 0.5) / NewWidth,
                            {Ax, Bx, Cx, Dx} = nearest_grid_points(XPos, IMG#erl_image.width),
                            Pos = {XPos * IMG#erl_image.width - Bx - 0.5, YPos * IMG#erl_image.height - By - 0.5},

                            Paa = get_pixel_bytes(IMG, Ax, Ay),
                            Pab = get_pixel_bytes(IMG, Bx, Ay),
                            Pac = get_pixel_bytes(IMG, Cx, Ay),
                            Pad = get_pixel_bytes(IMG, Dx, Ay),

                            Pba = get_pixel_bytes(IMG, Ax, By),
                            Pbb = get_pixel_bytes(IMG, Bx, By),
                            Pbc = get_pixel_bytes(IMG, Cx, By),
                            Pbd = get_pixel_bytes(IMG, Dx, By),

                            Pca = get_pixel_bytes(IMG, Ax, Cy),
                            Pcb = get_pixel_bytes(IMG, Bx, Cy),
                            Pcc = get_pixel_bytes(IMG, Cx, Cy),
                            Pcd = get_pixel_bytes(IMG, Dx, Cy),

                            Pda = get_pixel_bytes(IMG, Ax, Dy),
                            Pdb = get_pixel_bytes(IMG, Bx, Dy),
                            Pdc = get_pixel_bytes(IMG, Cx, Dy),
                            Pdd = get_pixel_bytes(IMG, Dx, Dy),

                            lists:map(fun(ChannelNum) ->
                                        <<CHaa:Depth>> = binary:part(Paa, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHab:Depth>> = binary:part(Pab, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHac:Depth>> = binary:part(Pac, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHad:Depth>> = binary:part(Pad, ChannelNum * BytesPerChannel, BytesPerChannel),

                                        <<CHba:Depth>> = binary:part(Pba, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHbb:Depth>> = binary:part(Pbb, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHbc:Depth>> = binary:part(Pbc, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHbd:Depth>> = binary:part(Pbd, ChannelNum * BytesPerChannel, BytesPerChannel),

                                        <<CHca:Depth>> = binary:part(Pca, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHcb:Depth>> = binary:part(Pcb, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHcc:Depth>> = binary:part(Pcc, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHcd:Depth>> = binary:part(Pcd, ChannelNum * BytesPerChannel, BytesPerChannel),

                                        <<CHda:Depth>> = binary:part(Pda, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHdb:Depth>> = binary:part(Pdb, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHdc:Depth>> = binary:part(Pdc, ChannelNum * BytesPerChannel, BytesPerChannel),
                                        <<CHdd:Depth>> = binary:part(Pdd, ChannelNum * BytesPerChannel, BytesPerChannel),

                                        CHi = round(clamp(interpolate_bicubic(Pos,
                                                    {CHaa, CHab, CHac, CHad},
                                                    {CHba, CHbb, CHbc, CHbd},
                                                    {CHca, CHcb, CHcc, CHcd},
                                                    {CHda, CHdb, CHdc, CHdd}), Depth)),
                                        <<CHi:Depth>>
                                end, lists:seq(0, NumChannels - 1))
                    end, lists:seq(0, NewWidth - 1)),
                {RowNum, iolist_to_binary(RowPixels)}
        end, lists:seq(0, NewHeight - 1)).

scale(IMG, ScaleFactor) ->
    scale(IMG, ScaleFactor, ScaleFactor).

scale(IMG, XScaleFactor, YScaleFactor) ->
    NewHeight = round(YScaleFactor * IMG#erl_image.height),
    NewWidth = round(XScaleFactor * IMG#erl_image.width),
    IMG#erl_image{
        pixmaps = [#erl_pixmap{ 
                left = 0,
                top = 0,
                width = NewWidth,
                height = NewHeight,
                pixels = resample_pixels(IMG, NewWidth, NewHeight)}],
        width = NewWidth,
        height = NewHeight }.
