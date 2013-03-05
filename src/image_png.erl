%%% File    : image_png.erl
%%% Author  : Tony Rogvall <tony@bix.hemma.se>
%%% Description : PNG Files
%%% Created :  5 Mar 2003 by Tony Rogvall <tony@bix.hemma.se>

-module(image_png).

-include_lib("erl_img.hrl").
-include("api.hrl").

-include("dbg.hrl").

-import(lists, [reverse/1]).
-import(erl_img, [attribute/3, set_attribute/3]).

-define(MAGIC, 137,$P,$N,$G,$\r,$\n,26,$\n).

-define(IHDR, "IHDR"). %% image header
-define(PLTE, "PLTE"). %% palette
-define(IDAT, "IDAT"). %% image data
-define(IEND, "IEND"). %% image trailer

-define(bKGD, "bKGD"). %% background color
-define(cHRM, "cHRM"). %% primary chromaticites and white point
-define(gAMA, "gAMA"). %% Image gamma
-define(hIST, "hIST"). %% Image histogram
-define(pHYs, "pHYs"). %% Physical pixel dimensions
-define(sBIT, "sBIT"). %% Significant bits
-define(tEXt, "tEXt"). %% Textual data
-define(tIME, "tIME"). %% Image last modification time
-define(tRNS, "tRNS"). %% Transparency
-define(zTXt, "zTXt"). %% Compressed textual data

magic(<<?MAGIC, _/binary>>) -> true;
magic(_) -> false.

mime_type() -> "image/png".

extensions() -> [ ".png" ].

read_info(Fd) ->
    case file:read(Fd, 8) of
        {ok, << ?MAGIC >> } ->
            scan_info(Fd, #erl_image { type = ?MODULE }, true);
        {ok, _} ->
            {error, bad_magic};
        Error ->
            Error
    end.

scan_info(Fd, IMG, First) ->
    case read_chunk_hdr(Fd) of
        {ok, Length, Type} ->
            Z = zlib:open(),
            Res = scan_info(Fd, IMG, First, Type, Length, Z),
            zlib:close(Z),
			Res;
        Error ->
            Error
    end.

scan_info(Fd, IMG, true, ?IHDR, Length, Z) ->
    case read_chunk_crc(Fd, Length, Z) of
        {ok,  <<Width:32, Height:32, BitDepth:8,
               ColorType:8, CompressionMethod:8,
               FilterMethod:8, InterlaceMethod:8, _/binary >>} ->
               Format = format(ColorType,BitDepth),
            scan_info(Fd, IMG#erl_image {
                            width = Width,
                            height = Height,
                            depth = BitDepth,
                            format = Format,
                            bytes_pp = bpp(Format),
                            order  = left_to_right,
                            attributes =
                            [ {'ColorType', ColorType},
                              {'Compression', CompressionMethod},
                              {'Filter', FilterMethod },
                              {'Interlace', InterlaceMethod }]}, false);
        Error -> Error
    end;
scan_info(Fd, IMG, false, ?tEXt, Length, Z) ->
    case read_chunk_crc(Fd, Length, Z) of
        {ok, Bin} ->
            scan_info(Fd, update_txt(IMG, Bin), false);
        Error -> Error
    end;
scan_info(Fd, IMG, false, ?zTXt, Length, Z) ->
    case read_chunk_crc(Fd, Length, Z) of
        {ok, Bin} ->
            [Key, CompressedValue] = binary:split(Bin, <<0, 0>>),
            Value = zlib:uncompress(CompressedValue),
            scan_info(Fd, set_attribute(IMG, list_to_atom(binary_to_list(Key)), binary_to_list(Value)), false);
        Error -> Error
    end;
scan_info(Fd, IMG, false, ?bKGD, Length, Z) ->
    CT = attribute(IMG, 'ColorType', undefined),
    case read_chunk_crc(Fd, Length, Z) of
        {ok, <<Index:8>>} when CT==3 ->
            scan_info(Fd, set_attribute(IMG, 'Background', Index), false);
        {ok, <<Gray:16>>} when CT==0; CT==4 ->
            scan_info(Fd, set_attribute(IMG, 'Background', Gray), false);
        {ok, <<R:16,G:16,B:16>>} when CT==2; CT==6 ->
            scan_info(Fd, set_attribute(IMG, 'Background', {R,G,B}), false);
        {ok, _Data} ->
            ?dbg("bKGD other=~p\n", [_Data]),
            scan_info(Fd, IMG, false);
        Error -> Error
    end;
scan_info(Fd, IMG, false, ?tIME, Length, Z) ->
    case read_chunk_crc(Fd, Length, Z) of
        {ok, <<Year:16, Mon:8, Day:8, H:8, M:8, S:8>>} ->
            scan_info(Fd, IMG#erl_image { mtime = {{Year,Mon,Day},
                                                   {H,M,S}} }, false);
        {ok, _Data} ->
            ?dbg("tIME other=~p\n", [_Data]),
            scan_info(Fd, IMG, false);
        Error -> Error
    end;
scan_info(Fd, IMG, false, ?pHYs, Length, Z) ->
    case read_chunk_crc(Fd, Length, Z) of
        {ok, <<X:32, Y:32, _Unit:8>>} ->
            scan_info(Fd, set_attribute(IMG,'Physical',{X,Y,meter}),false);
        {ok, _Data} ->
            ?dbg("pHYs other=~p\n", [_Data]),
            scan_info(Fd, IMG, false);
        Error -> Error
    end;
scan_info(Fd, IMG, false, ?tRNS, Length, Z) ->
    CT = attribute(IMG, 'ColorType', undefined),
    case read_chunk_crc(Fd, Length, Z) of
        {ok, <<Gray:16>>} when CT == 0 ->
            scan_info(Fd, set_attribute(IMG, 'Transparent', Gray), false);
        {ok, <<R:16, B:16, G:16>>} when CT == 2 ->
            scan_info(Fd, set_attribute(IMG, 'Transparent', {R,G,B}), false);
        {ok, Binary} when CT == 3 ->
            scan_info(Fd, IMG#erl_image { alpha_table = binary_to_list(Binary) }, false);
        Error -> Error
    end;
scan_info(_Fd, IMG, false, ?IEND, 0, _Z) ->
    {ok, IMG};
scan_info(Fd, IMG, false, _Type, Length, _Z) ->
    ?dbg("~s skipped=~p\n", [_Type,Length]),
    skip_chunk(Fd, Length),
    scan_info(Fd, IMG, false).

%% Update txt attributes
update_txt(IMG, Txt) ->
    case txt(binary_to_list(Txt), []) of
        {value,{Key,Value}} ->
            case Key of
                'Comment' ->
                    IMG#erl_image { comment = Value };
                _ ->
                    As = [{Key,Value} | IMG#erl_image.attributes],
                    IMG#erl_image { attributes = As }
            end;
        false ->
            IMG
    end.


%% determine the erl_image format
bytes_per_row(gray1,W) -> W div 8;
bytes_per_row(gray2,W) -> W div 4;
bytes_per_row(gray4,W) -> W div 2;
bytes_per_row(gray8,W) -> W;
bytes_per_row(gray16,W) -> W*2;
bytes_per_row(r8g8b8,W) -> W*3;
bytes_per_row(r16g16b16,W) -> W*6;
bytes_per_row(palette1,W) -> W div 8;
bytes_per_row(palette2,W) -> W div 4;
bytes_per_row(palette4,W) -> W div 2;
bytes_per_row(palette8,W) -> W;
bytes_per_row(gray8a8,W) -> W*2;
bytes_per_row(gray16a16,W) -> W*4;
bytes_per_row(r8g8b8a8,W) -> W*4;
bytes_per_row(r16g16b16a16,W) -> W*8.


bpp(gray1) -> 1;
bpp(gray2) -> 1;
bpp(gray4) -> 1;
bpp(gray8) -> 1;
bpp(gray16) -> 2;
bpp(r8g8b8) -> 3;
bpp(r16g16b16) -> 6;
bpp(palette1) -> 1;
bpp(palette2) -> 1;
bpp(palette4) -> 1;
bpp(palette8) -> 1;
bpp(gray8a8)  -> 2;
bpp(gray16a16) -> 4;
bpp(r8g8b8a8) -> 4;
bpp(r16g16b16a16) -> 8.


format(0, 1)  -> gray1;
format(0, 2)  -> gray2;
format(0, 4)  -> gray4;
format(0, 8)  -> gray8;
format(0, 16) -> gray16;
format(2, 8)  -> r8g8b8;
format(2, 16) -> r16g16b16;
format(3, 1)  -> palette1;
format(3, 2)  -> palette2;
format(3, 4)  -> palette4;
format(3, 8)  -> palette8;
format(4, 8)  -> gray8a8;
format(4, 16) -> gray16a16;
format(6, 8)  -> r8g8b8a8;
format(6, 16) -> r16g16b16a16.

color_type(gray1) -> 0;
color_type(gray2) -> 0;
color_type(gray4) -> 0;
color_type(gray8) -> 0;
color_type(gray16) -> 0;
color_type(r8g8b8) -> 2;
color_type(r16g16b16) -> 2;
color_type(palette1) -> 3;
color_type(palette2) -> 3;
color_type(palette4) -> 3;
color_type(palette8) -> 3;
color_type(gray8a8) -> 4;
color_type(gray16a16) -> 4;
color_type(r8g8b8a8) -> 6;
color_type(r16g16b16a16) -> 6.


%% process text chunk
txt([0|Value], RKey) ->
    {value, {list_to_atom(reverse(RKey)), Value}};
txt([C|Cs], RKey) ->
    txt(Cs,[C|RKey]);
txt([], _) ->
    false.

%% read palette
plte(<<R,G,B, Data/binary>>) ->
    [{R,G,B} | plte(Data)];
plte(<<>>) -> [].

write_info(Fd, IMG) ->
    Z = zlib:open(),
    write_info(Fd, IMG, Z),
    zlib:close(Z),
    ok.

write_info(Fd, IMG, Z) ->
    file:write(Fd, <<?MAGIC>>),
    ColorType = color_type(IMG#erl_image.format),
    write_chunk_crc(Fd, ?IHDR, <<
        (IMG#erl_image.width):32, 
        (IMG#erl_image.height):32,
        (IMG#erl_image.depth):8,
        ColorType,
        0, % Compression method
        0, % Filter method
        0  % Interlacing
        >>, Z).

write_chunk_crc(Fd, ChunkName, Chunk, Z) ->
    Binary = iolist_to_binary(Chunk),
    Length = byte_size(Binary),
    ChunkNameBinary = list_to_binary(ChunkName),
    CRC32 = zlib:crc32(Z, <<ChunkNameBinary/binary, Binary/binary>>),
    file:write(Fd, <<(Length):32, ChunkNameBinary/binary, Binary/binary, (CRC32):32>>).

write(Fd, IMG) ->
    Z = zlib:open(),
    write_info(Fd, IMG, Z),
    zlib:deflateInit(Z),
    case IMG#erl_image.format of
        Format when Format=:=palette1; Format=:=palette2; Format=:=palette4; Format=:=palette8 ->
            PaletteChunk = << <<R:8, G:8, B:8>> || {R, G, B} <- IMG#erl_image.palette >>,
            write_chunk_crc(Fd, ?PLTE, PaletteChunk, Z);
        _ ->
            ok
    end,
    ColorType = color_type(IMG#erl_image.format),
    case attribute(IMG, 'Background', undefined) of
        undefined -> ok;
        Val ->
            BackgroundChunk = case ColorType of
                0 -> <<Val:16>>;
                2 -> {R, G, B} = Val, <<R:16, G:16, B:16>>;
                3 -> <<Val:8>>;
                4 -> <<Val:16>>;
                6 -> {R, G, B} = Val, <<R:16, G:16, B:16>>
            end,
            write_chunk_crc(Fd, ?bKGD, BackgroundChunk, Z)
    end,
    case attribute(IMG, 'Physical', undefined) of
        undefined -> ok;
        {X, Y, meter} -> write_chunk_crc(Fd, ?pHYs, <<X:32, Y:32, 1>>, Z);
        {X, Y, undefined} -> write_chunk_crc(Fd, ?pHYs, <<X:32, Y:32, 0>>, Z)
    end,
    case attribute(IMG, 'Transparent', undefined) of
        undefined -> ok;
        TrVal ->
            TransparentChunk = case ColorType of
                0 -> <<TrVal:16>>;
                2 -> {R0, G0, B0} = TrVal, <<R0:16, G0:16, B0:16>>
            end,
            write_chunk_crc(Fd, ?tRNS, TransparentChunk, Z)
    end,
    case IMG#erl_image.alpha_table of
        undefined -> ok;
        List when ColorType =:= 3 -> write_chunk_crc(Fd, ?tRNS, List, Z)
    end,

    Bpp = bpp(IMG#erl_image.format),
    FilterMethod = 0,

    PixMap = erlang:hd(IMG#erl_image.pixmaps),
    {_FinalRow, FilteredData} = lists:foldl(fun
            ({_RowNum, RowData}, {LastRow, Acc}) ->
                PixelData = case IMG#erl_image.order of
                    left_to_right -> RowData
                end,
                FilteredBytes = filter(FilterMethod, Bpp, PixelData, LastRow),
                {PixelData, [[FilterMethod, FilteredBytes]|Acc]}
        end, {undefined, []},
        lists:sort(fun({RowNum1, _Data1}, {RowNum2, _Data2}) -> 
                    RowNum1 < RowNum2
            end, PixMap#erl_pixmap.pixels)),
    CompressedData = zlib:deflate(Z, FilteredData, finish),
    write_chunk_crc(Fd, ?IDAT, CompressedData, Z),
    zlib:deflateEnd(Z),
    write_chunk_crc(Fd, ?IEND, <<>>, Z),
    zlib:close(Z),
    ok.


read(Fd, IMG) ->
    read(Fd, IMG,
         fun(_, Row, Ri, St) ->
                 ?dbg("png: load row ~p\n", [Ri]),
                 [{Ri,Row}|St] end,
         []).


read(Fd, IMG, RowFun, St0) ->
    file:position(Fd, 8), %% skip magic
    Z = zlib:open(),
    zlib:inflateInit(Z),
    Resp = read_image(Fd, [], undefined, Z),
    zlib:close(Z),
    case Resp of
        {ok, Binary, Palette} ->
            {ok,Pixmap} = decode_pixmap(IMG, Binary, Palette, RowFun, St0),
            {ok, IMG#erl_image { pixmaps = [Pixmap],
                                 palette = Palette }};
        Error -> Error
    end.

decode_pixmap(IMG, Bin, Palette, RowFun, St0) ->
    Interlace = attribute(IMG, 'Interlace', 0),
    Pix0 = #erl_pixmap { width  = IMG#erl_image.width,
                         height = IMG#erl_image.height,
                         palette = Palette,
                         format  = IMG#erl_image.format },
    Bpp = bpp(IMG#erl_image.format),
    BytesPerRow = bytes_per_row(
                    IMG#erl_image.format,IMG#erl_image.width),
    case Interlace of
        0 ->
            raw_data(Bin,Pix0,RowFun,St0,0,Bpp,BytesPerRow);
        1 ->
            interlaced_data(Bin, Pix0, RowFun, St0, Bpp)
    end.


raw_data(Bin,Pix,RowFun,St0,Ri,Bpp,Width) ->
    case Bin of
        <<Filter:8,Row:Width/binary,Bin1/binary>> ->
            Prior = case St0 of
                        [] -> <<>>;
                        [{_,Row0}|_] -> Row0
                    end,
            Row1 = reconstruct(Filter,Bpp,Row,Prior), %% Filter method=0 assumed
            St1 = RowFun(Pix,Row1,Ri,St0),
            raw_data(Bin1,Pix,RowFun,St1,Ri+1,Bpp,Width);
        _ ->
            {ok, Pix#erl_pixmap { pixels = St0 }}
    end.

interlaced_data(Bin, Pix0=#erl_pixmap{width=Width, height=Height},
                RowFun, St0, Bpp) ->
    [P1, P2, P3, P4, P5, P6, P7] = interlaced_pass(Bin, Width, Height, Bpp, 1),
    Passes = {P1, P2, P3, P4, P5, P6, P7},
    Cols = lists:seq(0, Width - 1),
    merge_adam7(Passes, Pix0, RowFun, St0, 0, Bpp, Cols, Height).

merge_adam7(_P, Pix, _RowFun, St0, Height, _Bpp, _Cols, Height) ->
    {ok, Pix#erl_pixmap{pixels=St0}};
merge_adam7(P, Pix, RowFun, St0, Ri, Bpp, Cols, Height) ->
    St1 = RowFun(Pix, merge_adam7_row(P, Ri, Bpp, Cols), Ri, St0),
    merge_adam7(P, Pix, RowFun, St1, 1 + Ri, Bpp, Cols, Height).

%% 1 6 4 6 2 6 4 6
%% 7 7 7 7 7 7 7 7
%% 5 6 5 6 5 6 5 6
%% 7 7 7 7 7 7 7 7
%% 3 6 4 6 3 6 4 6
%% 7 7 7 7 7 7 7 7
%% 5 6 5 6 5 6 5 6
%% 7 7 7 7 7 7 7 7
merge_adam7_row(P, Ri, _Bpp, _Cols) when Ri band 1 =:= 1 ->
    %% 7 7 7 7 7 7 7 7
    array:get(Ri, element(7, P));
merge_adam7_row(P, Ri, Bpp, Cols) ->
    << <<(adam7_pixel(P, Ri, Bpp, Col))/binary>> || Col <- Cols >>.

adam7_pixel(P, Ri, Bpp, Col) when Ri band 1 =:= 1 ->
    %% [7 7 7 7 7 7 7 7]
    binary:part(array:get(Ri, element(7, P)), Col * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 0 andalso Col band 7 =:= 0 ->
    %% [1] 6 4 6 2 6 4 6
    binary:part(array:get(Ri, element(1, P)), (Col div 8) * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 0 andalso Col band 1 =:= 1 ->
    %% 1 [6] 4 [6] 2 [6] 4 [6]
    binary:part(array:get(Ri, element(6, P)), (Col div 2) * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 0 andalso
                                  (Col band 7 =:= 2 orelse Col band 7 =:= 6) ->
    %% 1 6 [4] 6 2 6 [4] 6
    binary:part(array:get(Ri, element(4, P)), (Col div 4) * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 0 andalso
                                  (Col band 7 =:= 2 orelse Col band 7 =:= 4) ->
    %% 1 6 4 6 [2] 6 4 6
    binary:part(array:get(Ri, element(2, P)), (Col div 8) * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 2 orelse Ri band 7 =:= 6 ->
    %% [5 6 5 6 5 6 5 6]
    binary:part(array:get(Ri, element(5 + (Col band 1), P)),
                (Col div 2) * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 4 andalso Col band 3 =:= 0 ->
    %% [3] 6 4 6 [3] 6 4 6
    binary:part(array:get(Ri, element(3, P)), (Col div 4) * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 4 andalso Col band 1 =:= 1 ->
    %% 3 [6] 4 [6] 3 [6] 4 [6]
    binary:part(array:get(Ri, element(6, P)), (Col div 2) * Bpp, Bpp);
adam7_pixel(P, Ri, Bpp, Col) when Ri band 7 =:= 4 andalso
                                  (Col band 7 =:= 2 orelse Col band 7 =:= 6) ->
    %% 3 6 [4] 6 3 6 [4] 6
    binary:part(array:get(Ri, element(4, P)), (Col div 4) * Bpp, Bpp).




interlaced_pass(_Bin, _Width, _Height, _Bpp, 8) ->
    [];
interlaced_pass(Bin, Width, Height, Bpp, N) ->
    {RowLen, RowInc, RowStart} = get_row_info(Bpp, Width, N),
    {Data, Bin1} = read_interlaced_data(Bin, Width, Height, RowStart, Bpp,
                                        RowLen, RowInc, []),
    [array:from_orddict(lists:reverse(Data))
     | interlaced_pass(Bin1, Width, Height, Bpp, 1 + N)].

read_interlaced_data(Bin, _Width, Height, RowNum, _Bpp, RowLen, _RowInc, St0)
  when RowNum >= Height orelse RowLen =:= 0 ->
    {St0, Bin};
read_interlaced_data(Bin, Width, Height, RowNum, Bpp, RowLen, RowInc, St0) ->
    case Bin of
        <<Filter:8,Row:RowLen/binary,Bin1/binary>> ->
            Prior = case St0 of
                        [] -> <<>>;
                        [{_,Row0}|_] -> Row0
                    end,
            Row1 = reconstruct(Filter,Bpp,Row,Prior), %% Filter method=0 assumed
            read_interlaced_data(Bin1, Width, Height, RowInc + RowNum, Bpp,
                                 RowLen, RowInc,
                                 [{RowNum, Row1} | St0]);
        _ ->
            {St0, Bin}
    end.

get_row_info(BPP, Width, Pass) ->
    RowLen = (Width + adam7(offset, Pass)) div adam7(col_increment, Pass),
    {RowLen * BPP, adam7(row_increment, Pass), adam7(starting_row, Pass)}.

adam7(offset, N) -> element(N, { 7, 3, 3, 1, 1, 0, 0 });
%% adam7(starting_col, N) -> element(N, { 0, 4, 0, 2, 0, 1, 0 });
adam7(starting_row, N) -> element(N, { 0, 0, 4, 0, 2, 0, 1 });
adam7(col_increment, N) -> element(N, { 8, 8, 4, 4, 2, 2, 1 });
adam7(row_increment, N) -> element(N, { 8, 8, 8, 4, 4, 2, 2 }).

filter(0, _, Row, _) -> Row.

reconstruct(0,_,Row,_Prior) -> Row;
reconstruct(1, Bpp, Row, Prior) -> reconstruct_sub(Row,Prior,Bpp);
reconstruct(2, Bpp, Row,Prior) -> reconstruct_up(Row,Prior,Bpp);
reconstruct(3, Bpp, Row,Prior) -> reconstruct_avg(Row,Prior,Bpp);
reconstruct(4, Bpp, Row,Prior) -> reconstruct_paeth(Row,Prior,Bpp).

%% Neighboring bytes are in the matrix:
%% c b
%% a x
%% See: http://www.w3.org/TR/PNG/#9Filter-types

%% Filt(x) = Orig(x) - Orig(a)
%% Recon(x) = Filt(x) + Recon(a)  
%%
reconstruct_sub(Sub,_Prior,Bpp) ->
    Rn = lists:duplicate(Bpp, 0),
    Rm = [],
    reconstruct_sub(Sub, 0, size(Sub), [], Rn, Rm).

reconstruct_sub(_Sub, X, X, Acc, _, _) ->
    list_to_binary(reverse(Acc));
reconstruct_sub(Sub, X, N, Acc, [Rxb|Rn], Rm) ->
    <<_:X/binary, Sx:8, _/binary>> = Sub,
    Rx = (Sx + Rxb) band 16#ff,
    if Rn == [] ->
            reconstruct_sub(Sub,X+1,N,[Rx|Acc],reverse([Rx|Rm]),[]);
       true ->
            reconstruct_sub(Sub,X+1,N,[Rx|Acc],Rn,[Rx|Rm])
    end.

%% Filt(x) = Orig(x) - Orig(b)
%% Recon(x) = Filt(x) + Recon(b)
%%
reconstruct_up(Up, Prior, _Bpp) ->
    reconstruct_up(Up, Prior, 0, size(Up), []).

reconstruct_up(_Up, _Prior, X, X, Acc) ->
    list_to_binary(reverse(Acc));
reconstruct_up(Up, Prior, X, N, Acc) ->
    <<_:X/binary,Ux:8,_/binary>> = Up,
    Px = case Prior of
             <<_:X/binary,Pi,_/binary>> -> Pi;
             _ -> 0
         end,
    Rx = (Ux + Px) band 16#ff,
    reconstruct_up(Up,Prior,X+1,N,[Rx|Acc]).

%%
%% Filt(x) = Orig(x) - floor((Orig(a) + Orig(b))/2)
%% Recon(x) = Filt(x) + floor((Recon(a) + Recon(b))/2)
%%

reconstruct_avg(Avg, Prior,Bpp) ->
    Rn = lists:duplicate(Bpp, 0),
    Rm = [],
    reconstruct_avg(Avg, Prior,  0, size(Avg), [], Rn, Rm).

reconstruct_avg(_Avg,_Prior, X, X, Acc, _, _) ->
    list_to_binary(reverse(Acc));
reconstruct_avg(Avg, Prior, X, N, Acc, [Rxb|Rn], Rm) ->
    <<_:X/binary, Ax:8, _/binary>> = Avg,
    Px = case Prior of
             <<_:X/binary,Pi,_/binary>> -> Pi;
             _ -> 0
         end,
    Rx = (Ax + ((Rxb+Px) div 2)) band 16#ff,
    if Rn == [] ->
            reconstruct_avg(Avg,Prior,X+1,N,[Rx|Acc],reverse([Rx|Rm]),[]);
       true ->
            reconstruct_avg(Avg,Prior,X+1,N,[Rx|Acc],Rn,[Rx|Rm])
    end.

%% Filt(x) = Orig(x) - PaethPredictor(Orig(a),Orig(b),Orig(c))
%% Recon(x) = Filt(x) + PaethPredictor(Recon(a), Recon(b), Recon(c))
%%
reconstruct_paeth(Pae,Prior,Bpp) ->
    Pn = Rn = lists:duplicate(Bpp, 0),
    Pm = Rm = [],
    reconstruct_paeth(Pae, Prior, 0, size(Pae), [], Rn, Rm, Pn, Pm).


reconstruct_paeth(_Pae, _Prior, X, X, Acc, _Rn, _Rm, _Pn, _Pm) ->
    list_to_binary(reverse(Acc));
reconstruct_paeth(Pae, Prior, X, N, Acc, [Rxb|Rn], Rm, [Pxb|Pn], Pm) ->
    <<_:X/binary, PAx:8, _/binary>> = Pae,
    Px = case Prior of
             <<_:X/binary,Pi,_/binary>> -> Pi;
             _ -> 0
         end,
    Rx = (PAx + paethPredictor(Rxb, Px, Pxb)) band 16#ff,
    if Rn == [] ->
            reconstruct_paeth(Pae,Prior,X+1,N,[Rx|Acc],
                       reverse([Rx|Rm]),[],
                       reverse([Px|Pm]),[]);
       true ->
            reconstruct_paeth(Pae,Prior,X+1,N,[Rx|Acc],
                       Rn,[Rx|Rm],
                       Pn,[Px|Pm])
    end.

-define(dabs(X,Y),
        if (X) > (Y) -> (X) - (Y);
           true -> (Y) - (X)
        end).

paethPredictor(A,B,C) ->
    P = A + B - C,
    PA = ?dabs(P,A),
    PB = ?dabs(P,B),
    PC = ?dabs(P,C),
    if PA =< PB, PA =< PC -> A;
       PB =< PC -> B;
       true -> C
    end.








read_image(Fd, Acc, Palette, Z) ->
    case read_chunk_hdr(Fd) of
        {ok, Length, ?IDAT} ->
            case read_chunk_crc(Fd, Length, Z) of
                {ok, CBin} ->
                    Blocks = zlib:inflate(Z, CBin),
                    read_image(Fd, [Blocks|Acc], Palette, Z);
                Error -> Error
            end;
        {ok, _Length, ?IEND} ->
            zlib:inflateEnd(Z),
            {ok, list_to_binary(reverse(Acc)), Palette};

        {ok, Length, ?PLTE} ->
            case read_chunk_crc(Fd, Length, Z) of
                {ok, Chunk} ->
                    read_image(Fd, Acc, plte(Chunk), Z);
                Error ->
                    Error
            end;
        {ok, Length, _} ->
            skip_chunk(Fd, Length),
            read_image(Fd, Acc, Palette, Z)
    end.

%%
%% Given chunk header read chunk and check crc
%%
read_chunk_crc(Fd, Length, Z) ->
    file:position(Fd, {cur,-4}),
    LengthWithType = Length+4,
    case file:read(Fd, LengthWithType+4) of
        {ok,<<TypeChunk:LengthWithType/binary, CRC:32>>} ->
            case valid_crc32(TypeChunk, CRC, Z) of
                true ->
                    <<_:32, Chunk/binary>> = TypeChunk,
                    {ok, Chunk};
                false ->
                    {error, bad_crc}
            end;
        {ok,_} ->
            {error, bad_chunk};
        Error ->
            Error
    end.

%%
%% Read the chunk header
%%

read_chunk_hdr(Fd) ->
    case file:read(Fd, 8) of
        {ok, <<Length:32, Type:4/binary>>} ->
            Tag = binary_to_list(Type),
            ?dbg("chunk: type = ~p, length=~p\n", [Tag,Length]),
            {ok, Length, Tag};
        Error ->
            Error
    end.


skip_chunk(Fd, Length) ->
    file:position(Fd, {cur,Length+4}).

valid_crc32(Binary, Value, Z) ->
    CRC32 = zlib:crc32(Z, Binary),
    ?dbg("crc check: ~p == ~p\n", [CRC32, Value]),
    CRC32 == Value.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%%
%% These tests use the pngsuite of test pngs from the libpng
%% website to verify all sorts of things.  The intentionally corrupt
%% pngs live in priv/pngsuite/corrupted because I didn't want
%% to deal with them right now, see should probably write
%% some more acceptance tests that ensures those fail for
%% specific reasons.
%%
png_suite_files() ->
    application:start(erl_img),
    PrivDir = code:priv_dir(erl_img),
    %% Skip tests for unsupported 1-bit, 2-bit, 4-bit color
    {ok, SkipRegex} = re:compile("0[124]\\.png"),
    lists:filter(
      fun (Fn) -> nomatch =:= re:run(Fn, SkipRegex) end,
      filelib:wildcard(PrivDir ++ "/pngsuite/*.png")).

%% Use a macro here so png_suite_*_test_ shows up in the eunit output.
-define(PNG_SUITE_TEST(TestFun),
        [{filename:basename(FName),
          fun() ->
                  TestFun(FName)
          end}
         || FName <- png_suite_files()]).

png_suite_basic_interlace_test() ->
    application:start(erl_img),
    PrivDir = code:priv_dir(erl_img),
    [F0, F1] = lists:sort(
                 filelib:wildcard(PrivDir ++ "/pngsuite/bas[in]2c08.png")),
    Pm = fun (F) ->
                 {ok, _Img=#erl_image{pixmaps=[PM]}} = erl_img:load(F),
                 %% erl_img:save("/tmp/" ++ filename:basename(F) ++ ".tga",
                 %%              _Img#erl_image{type=image_tga}),
                 #erl_pixmap{pixels=Rows} = PM,
                 lists:sort(Rows)
         end,
    ?assertEqual(
       Pm(F0),
       Pm(F1)),
    ok.

merge_adam7_row_test_() ->
    %% 1 6 4 6 2 6 4 6
    %% 7 7 7 7 7 7 7 7
    %% 5 6 5 6 5 6 5 6
    %% 7 7 7 7 7 7 7 7
    %% 3 6 4 6 3 6 4 6
    %% 7 7 7 7 7 7 7 7
    %% 5 6 5 6 5 6 5 6
    %% 7 7 7 7 7 7 7 7
    P = {array:from_orddict([{0, <<1>>}]),
         array:from_orddict([{0, <<2>>}]),
         array:from_orddict([{4, <<3, 3>>}]),
         array:from_orddict([{0, <<4, 4>>},
                             {4, <<4, 4>>}]),
         array:from_orddict([{2, <<5, 5, 5, 5>>},
                             {6, <<5, 5, 5, 5>>}]),
         array:from_orddict([{0, <<6, 6, 6, 6>>},
                             {2, <<6, 6, 6, 6>>},
                             {4, <<6, 6, 6, 6>>},
                             {6, <<6, 6, 6, 6>>}]),
         array:from_orddict([{1, <<7, 7, 7, 7, 7, 7, 7, 7>>},
                             {3, <<7, 7, 7, 7, 7, 7, 7, 7>>},
                             {5, <<7, 7, 7, 7, 7, 7, 7, 7>>},
                             {7, <<7, 7, 7, 7, 7, 7, 7, 7>>}])},
    ExpectList = [{0, <<1, 6, 4, 6, 2, 6, 4, 6>>},
                  {1, <<7, 7, 7, 7, 7, 7, 7, 7>>},
                  {2, <<5, 6, 5, 6, 5, 6, 5, 6>>},
                  {3, <<7, 7, 7, 7, 7, 7, 7, 7>>},
                  {4, <<3, 6, 4, 6, 3, 6, 4, 6>>},
                  {5, <<7, 7, 7, 7, 7, 7, 7, 7>>},
                  {6, <<5, 6, 5, 6, 5, 6, 5, 6>>},
                  {7, <<7, 7, 7, 7, 7, 7, 7, 7>>}],
    [(fun ({N, Expect}) ->
              {"row_" ++ integer_to_list(N),
               fun () ->
                       ?assertEqual(
                          Expect,
                          merge_adam7_row(P, N, 1, lists:seq(0, 7)))
               end}
      end)(X) || X <- ExpectList].


png_suite_read_test_() ->
    ?PNG_SUITE_TEST(
      fun(FileName) ->
              {ok, Fd} = file:open(FileName, [read, binary]),
              {ok, Info} = read_info(Fd),
              {ok, 0} = file:position(Fd, 0),
              ?assertMatch({ok, _}, read(Fd, Info))
      end).

png_suite_magic_test_() ->
    ?PNG_SUITE_TEST(
      fun(FileName) ->
              {ok, Bin} = file:read_file(FileName),
              ?assertEqual(true, magic(Bin))
      end).

non_png_magic_test() ->
    ?assertEqual(false, magic(<<"notapng">>)).

mime_type_test() ->
    ?assertEqual("image/png", mime_type()).

extensions_test() ->
    ?assertEqual([".png"], extensions()).

-endif.
