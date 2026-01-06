/* =============================================================================
 * gomoku.v
 * 目的：在 DE10-Lite + DIC-CV External Board 上實作簡化版五子棋（目前棋盤 16x16）
 *       - KeyPad：移動游標 + 落子（5）
 *       - Btn0：落子（視為一個額外確認鍵，通常為按下=0 的 active-low 按鍵）
 *       - VGA：顯示棋盤、棋子、游標
 *       - Dot Matrix：顯示落子成功(圈) / 失敗(叉)；另一塊顯示勝者
 *       - 七段顯示器：顯示回合倒數秒數（兩位數）
 *
 * 架構概觀：
 *   freqDiv            : 由 50MHz 產生 VGA/Keypad/Dot/7seg 所需節拍
 *   checkPad           : 4x4 KeyPad 掃描，輸出 raw_valid/raw_code（可能長按連續）
 *   keypad_onepress_cdc: 將長按變成「每次按下只輸出一次脈衝」並做跨時脈同步
 *   game_fsm           : 遊戲狀態/游標/落子/換手/勝負控制
 *   board_mem          : 棋盤記憶體（16x16，2-bit：00空、01 P1、10 P2）
 *   win_checker        : 以最後一次落子為中心，檢查四方向是否達 5 連
 *   vga_display        : VGA timing + 像素繪圖（背景、格線、棋子、游標）
 *   turn_timer         : 回合倒數計時（預設 99 秒）
 *   dotmatrix_check    : 顯示圈/叉（place_result）
 *   dotmatrix_winner   : 顯示勝者（game_over + winner）
 * ============================================================================= */

module gomoku(
    input        clk,
    input        rst,
    input        Btn0,

    output [3:0] VGA_R,     output [3:0] VGA_G,  output [3:0] VGA_B,
    output       VGA_HS,    output       VGA_VS,

    output [3:0] KeyPadRow, input  [3:0] KeyPadCol,

    output [7:0] Dot_row,
    output [7:0] Dot1_col,
    output [7:0] Dot2_col,

    output [6:0] HEX0,      output [6:0] HEX1
);

    /* -----------------------------
     * 時脈：由 freqDiv 分頻產生
     * ----------------------------- */
    wire clkVGA, clkPad, clkDot, clkSevenSegment;

    /* -----------------------------
     * KeyPad 原始掃描輸出（raw）
     * key_valid_raw：掃描到按鍵時為 1（可能長按一直為 1）
     * key_code_raw ：對應按鍵編碼（0~F）
     * ----------------------------- */
    wire        key_valid_raw;
    wire [3:0]  key_code_raw;

    /* -----------------------------
     * KeyPad 單次按壓事件輸出（去長按）
     * key_valid：每次「按下」只產生 1 個脈衝
     * key_code ：該次按下對應的 code
     * ----------------------------- */
    wire        key_valid;
    wire [3:0]  key_code;

    /* -----------------------------
     * 遊戲控制訊號
     * place_en     ：通知 board_mem 寫入棋子（成功落子才會拉高 1 cycle）
     * place_result ：00無、01成功、10失敗（Dot Matrix 顯示）
     * ----------------------------- */
    wire        place_en;
    wire [1:0]  place_result;

    /* -----------------------------
     * 游標座標（0~15）
     * ----------------------------- */
    wire [3:0] cursor_row;
    wire [3:0] cursor_col;

    /* -----------------------------
     * 玩家 / 棋盤資料
     * current_player ：01=P1、10=P2
     * cell_data      ：游標目前格子的內容（00空、01 P1、10 P2）
     * board_snapshot ：整個棋盤 16x16
     * ----------------------------- */
    wire [1:0] current_player;
    wire [1:0] cell_data;
    wire [1:0] board_snapshot [0:15][0:15];

    /* -----------------------------
     * 勝負判斷
     * win_flag  ：由 win_checker 輸出，代表最後落子形成 5 連
     * game_over ：遊戲結束
     * winner    ：勝者（01 P1、10 P2）
     * ----------------------------- */
    wire win_flag;
    wire game_over;
    wire [1:0] winner;

    /* -----------------------------
     * 回合倒數
     * turn_sec      ：剩餘秒數
     * timeout_pulse ：倒數歸零前最後一秒時產生的換手脈衝（在 timer 內定義）
     * turn_reset_pulse：換手或新回合時重置倒數
     * ----------------------------- */
    wire [6:0] turn_sec;
    wire timeout_pulse;
    wire turn_reset_pulse;

    /* -----------------------------
     * 最後一次落子位置/玩家（供 win_checker 使用）
     * ----------------------------- */
    wire [3:0] last_row;
    wire [3:0] last_col;
    wire [1:0] last_player;

    /* ============================================================
     * 分頻器：產生 VGA/Keypad/Dot/7seg 的節拍
     * ============================================================ */
    freqDiv u_freqDiv(
        .clk(clk),
        .rst(rst),
        .clk_vga(clkVGA),
        .clk_keypad(clkPad),
        .clk_dot(clkDot),
        .clk_7seg(clkSevenSegment)
    );

    /* ============================================================
     * KeyPad 掃描：輸出 raw_valid/raw_code
     * ============================================================ */
    checkPad u_checkPad(
        .clk_scan(clkPad),
        .rst(rst),
        .keypadRow(KeyPadRow),
        .keypadCol(KeyPadCol),
        .key_valid(key_valid_raw),
        .key_code(key_code_raw)
    );

    /* ============================================================
     * 單次按壓 + 跨時脈同步：
     * - clk_scan（掃描時脈域）偵測「一次按下」
     * - 透過 toggle + 3FF 同步到 clk（主時脈域）形成單 cycle 脈衝
     * ============================================================ */
    keypad_onepress_cdc #(
        .RELEASE_TH(3'd6)
    ) u_key_onepress (
        .clk_scan(clkPad),
        .clk(clk),
        .rst(rst),
        .raw_valid(key_valid_raw),
        .raw_code(key_code_raw),
        .key_valid(key_valid),
        .key_code(key_code)
    );

    /* ============================================================
     * 遊戲 FSM：游標移動、落子、換手、勝負
     * ============================================================ */
    game_fsm u_game_fsm(
        .clk(clk),
        .rst(rst),
        .key_valid(key_valid),
        .key_code(key_code),
        .btn0(Btn0),
        .current_cell_data(cell_data),
        .win_in(win_flag),
        .timeout_pulse(timeout_pulse),

        .place_en(place_en),
        .place_result(place_result),
        .game_over(game_over),
        .winner(winner),
        .turn_reset(turn_reset_pulse),

        .cursor_row(cursor_row),
        .cursor_col(cursor_col),
        .current_player(current_player),
        .last_row(last_row),
        .last_col(last_col),
        .last_player(last_player)
    );

    /* ============================================================
     * 回合倒數計時器：秒數輸出 turn_sec
     * ============================================================ */
    turn_timer u_turn_timer (
        .clk(clk),
        .rst(rst),
        .enable(~game_over),
        .reset_pulse(turn_reset_pulse),
        .sec_left(turn_sec),
        .timeout_pulse(timeout_pulse)
    );

    /* ============================================================
     * 七段顯示器：顯示 turn_sec 的十位/個位
     * 注意：HEX0/HEX1 使用 sevenseg_digit 只支援 0~9
     * ============================================================ */
    wire [3:0] sec_tens;
    wire [3:0] sec_ones;

    assign sec_tens = turn_sec / 7'd10;
    assign sec_ones = turn_sec % 7'd10;

    sevenseg_digit u_7seg0(.digit(sec_ones), .seg(HEX0));
    sevenseg_digit u_7seg1(.digit(sec_tens), .seg(HEX1));

    /* ============================================================
     * 棋盤記憶體：落子時寫入；同時提供游標格子的 cell_data
     * ============================================================ */
    board_mem u_board_mem(
        .clk(clk),
        .rst(rst),
        .write_en(place_en),
        .row(cursor_row),
        .col(cursor_col),
        .player(current_player),
        .cell_data(cell_data),
        .board(board_snapshot)
    );

    /* ============================================================
     * 勝負檢查：以 last_* 為中心，檢查是否 5 連
     * ============================================================ */
    win_checker u_win(
        .board(board_snapshot),
        .last_x(last_row),
        .last_y(last_col),
        .player(last_player),
        .win(win_flag)
    );

    /* ============================================================
     * VGA 顯示：棋盤、棋子、游標（游標顏色依 current_player）
     * ============================================================ */
    vga_display u_vga(
        .clk_vga(clkVGA),
        .rst(rst),
        .board(board_snapshot),
        .cursor_row(cursor_row),
        .cursor_col(cursor_col),
        .current_player(current_player),
        .VGA_R(VGA_R),
        .VGA_G(VGA_G),
        .VGA_B(VGA_B),
        .VGA_HS(VGA_HS),
        .VGA_VS(VGA_VS)
    );

    /* ============================================================
     * Dot Matrix 掃描列：row_index 逐列掃描（active-low）
     * Dot_row：選擇目前要亮的列
     * ============================================================ */
    reg [2:0] row_index;
    always @(posedge clkDot or negedge rst) begin
        if (!rst) row_index <= 3'd0;
        else      row_index <= row_index + 3'd1;
    end
    assign Dot_row = ~(8'b00000001 << row_index);

    /* ============================================================
     * Dot1：落子成功/失敗圖示（place_result）
     * Dot2：勝者圖示（game_over/winner）
     * ============================================================ */
    dotmatrix_check u_dot1(
        .place_result(place_result),
        .row_index(row_index),
        .dot_col(Dot1_col)
    );

    dotmatrix_winner u_dot2(
        .game_over(game_over),
        .winner(winner),
        .row_index(row_index),
        .dot_col(Dot2_col)
    );

endmodule


/* =============================================================================
 * module checkPad
 * 功能：4x4 KeyPad 掃描器
 * 原理：
 *   - keypadRow 逐列輸出 0（其餘為 1），形成列掃描
 *   - 讀取 keypadCol（通常為 active-low），若有任一 col 變 0 表示該列有鍵按下
 *   - 依「目前掃描列 keypadRow」+「哪一個 col 為 0」輸出 key_code
 * 注意：
 *   - 這裡的 key_valid 在按住鍵時會持續為 1（因此需搭配 onepress 模組）
 * ============================================================================= */
module checkPad(
    input             clk_scan,
    input             rst,
    output reg [3:0]  keypadRow,
    input      [3:0]  keypadCol,
    output reg        key_valid,
    output reg [3:0]  key_code
);
    reg [1:0] row_index;

    always @(posedge clk_scan or negedge rst) begin
        if (!rst) begin
            row_index <= 2'd0;
            keypadRow <= 4'b1110;
            key_valid <= 1'b0;
            key_code  <= 4'd0;
        end else begin
            if (keypadCol != 4'b1111) begin
                key_valid <= 1'b1;
                case (keypadRow)
                    4'b1110: begin
                        if (!keypadCol[3]) key_code <= 4'h0;
                        else if (!keypadCol[2]) key_code <= 4'h1;
                        else if (!keypadCol[1]) key_code <= 4'h4;
                        else if (!keypadCol[0]) key_code <= 4'h7;
                    end
                    4'b1101: begin
                        if (!keypadCol[3]) key_code <= 4'hA;
                        else if (!keypadCol[2]) key_code <= 4'h2;
                        else if (!keypadCol[1]) key_code <= 4'h5;
                        else if (!keypadCol[0]) key_code <= 4'h8;
                    end
                    4'b1011: begin
                        if (!keypadCol[3]) key_code <= 4'hB;
                        else if (!keypadCol[2]) key_code <= 4'h3;
                        else if (!keypadCol[1]) key_code <= 4'h6;
                        else if (!keypadCol[0]) key_code <= 4'h9;
                    end
                    4'b0111: begin
                        if (!keypadCol[3]) key_code <= 4'hF;
                        else if (!keypadCol[2]) key_code <= 4'hE;
                        else if (!keypadCol[1]) key_code <= 4'hD;
                        else if (!keypadCol[0]) key_code <= 4'hC;
                    end
                endcase
            end else begin
                key_valid <= 1'b0;
            end

            row_index <= row_index + 2'd1;
            case (row_index + 2'd1)
                2'd0: keypadRow <= 4'b1110;
                2'd1: keypadRow <= 4'b1101;
                2'd2: keypadRow <= 4'b1011;
                2'd3: keypadRow <= 4'b0111;
            endcase
        end
    end
endmodule


/* =============================================================================
 * module freqDiv
 * 功能：由主時脈 clk 分頻出多個子時脈（以 counter 到達門檻就 toggle）
 * 原理：
 *   - cnt_x 遞增到 EXP 之後歸零並翻轉 clk_x
 *   - 由於是 toggle，所以輸出頻率約為 clk / (2*(EXP+1))
 * 注意：
 *   - VGA_EXP=0：代表每個 clk 都 toggle => clk_vga = clk/2（50MHz->25MHz）
 * ============================================================================= */
module freqDiv(
    input  clk,
    input  rst,
    output reg clk_vga,
    output reg clk_keypad,
    output reg clk_dot,
    output reg clk_7seg
);

    reg [31:0] cnt_vga, cnt_keypad, cnt_dot, cnt_7seg;

    localparam VGA_EXP      = 32'd0;
    localparam KEYPAD_EXP   = 32'd249999;
    localparam DOT_EXP      = 32'd9999;
    localparam SEVENSEG_EXP = 32'd24999;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            cnt_vga    <= 32'd0;
            cnt_keypad <= 32'd0;
            cnt_dot    <= 32'd0;
            cnt_7seg   <= 32'd0;
            clk_vga    <= 1'b0;
            clk_keypad <= 1'b0;
            clk_dot    <= 1'b0;
            clk_7seg   <= 1'b0;
        end else begin
            if (cnt_vga >= VGA_EXP) begin
                cnt_vga <= 32'd0;
                clk_vga <= ~clk_vga;
            end else cnt_vga <= cnt_vga + 32'd1;

            if (cnt_keypad >= KEYPAD_EXP) begin
                cnt_keypad <= 32'd0;
                clk_keypad <= ~clk_keypad;
            end else cnt_keypad <= cnt_keypad + 32'd1;

            if (cnt_dot >= DOT_EXP) begin
                cnt_dot <= 32'd0;
                clk_dot <= ~clk_dot;
            end else cnt_dot <= cnt_dot + 32'd1;

            if (cnt_7seg >= SEVENSEG_EXP) begin
                cnt_7seg <= 32'd0;
                clk_7seg <= ~clk_7seg;
            end else cnt_7seg <= cnt_7seg + 32'd1;
        end
    end
endmodule


/* =============================================================================
 * module game_fsm
 * 功能：遊戲控制核心（游標移動、落子、回合切換、勝負結束）
 * 原理重點：
 *   1) 以 key_valid 的上升緣當成「一次按鍵事件」（已由 onepress 模組保證）
 *   2) confirm_pulse：Btn0 的按下事件 或 KeyPad 的 5（落子）
 *   3) 落子成功時 place_en=1 一個 cycle，並記錄 last_row/last_col/last_player
 *   4) pending_win_check：落子後等一拍讓 board_mem 寫入完成，再檢查 win_in
 *   5) timeout_pulse：倒數到最後一秒時觸發，直接換手並重置倒數
 *
 * 按鍵對應（本版本）：
 *   - 上：6  => cursor_row - 1
 *   - 下：4  => cursor_row + 1
 *   - 左：2  => cursor_col - 1
 *   - 右：8  => cursor_col + 1
 *   - 落子：5 或 Btn0
 * ============================================================================= */
module game_fsm(
    input        clk,
    input        rst,
    input        key_valid,
    input  [3:0] key_code,
    input        btn0,
    input  [1:0] current_cell_data,
    input        win_in,
    input        timeout_pulse,

    output reg        place_en,
    output reg [1:0]  place_result,
    output reg        game_over,
    output reg [1:0]  winner,
    output reg        turn_reset,

    output reg [3:0]  cursor_row,
    output reg [3:0]  cursor_col,
    output reg [1:0]  current_player,
    output reg [3:0]  last_row,
    output reg [3:0]  last_col,
    output reg [1:0]  last_player
);

    localparam P1 = 2'b01;
    localparam P2 = 2'b10;

    reg key_valid_prev;
    reg btn0_prev;

    wire key_valid_pos_edge = key_valid & ~key_valid_prev;

    /* Btn0 常見為 active-low：
     * btn0_press_edge = 1 表示「從 1 變 0」的按下事件 */
    wire btn0_press_edge = (~btn0) & btn0_prev;

    reg pending_win_check;

    /* confirm_pulse：落子確認事件（Btn0 或 KeyPad 5） */
    wire confirm_pulse = btn0_press_edge | (key_valid_pos_edge && (key_code == 4'h5));

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            current_player    <= P1;
            place_en          <= 1'b0;
            place_result      <= 2'b00;
            game_over         <= 1'b0;
            winner            <= 2'b00;
            turn_reset        <= 1'b0;

            cursor_row        <= 4'd0;
            cursor_col        <= 4'd0;
            last_row          <= 4'd0;
            last_col          <= 4'd0;
            last_player       <= 2'b00;

            key_valid_prev    <= 1'b0;
            btn0_prev         <= 1'b1;
            pending_win_check <= 1'b0;
        end else begin
            place_en   <= 1'b0;
            turn_reset <= 1'b0;

            key_valid_prev <= key_valid;
            btn0_prev      <= btn0;

            /* 落子後延遲一拍檢查勝負：確保 board_mem 已寫入 */
            if (pending_win_check) begin
                pending_win_check <= 1'b0;

                if (win_in) begin
                    game_over <= 1'b1;
                    winner    <= current_player;
                end else begin
                    current_player <= (current_player == P1) ? P2 : P1;
                    turn_reset     <= 1'b1;
                end
            end

            if (!game_over) begin
                /* 超時直接換手 */
                if (!pending_win_check && timeout_pulse) begin
                    current_player <= (current_player == P1) ? P2 : P1;
                    place_result   <= 2'b00;
                    turn_reset     <= 1'b1;
                end

                /* 游標移動：每個按鍵事件只移動一格 */
                if (!pending_win_check && key_valid_pos_edge) begin
                    if (key_code == 4'h6) begin
                        if (cursor_row != 4'd0)  cursor_row <= cursor_row - 4'd1;
                        place_result <= 2'b00;
                    end else if (key_code == 4'h4) begin
                        if (cursor_row != 4'd15) cursor_row <= cursor_row + 4'd1;
                        place_result <= 2'b00;
                    end else if (key_code == 4'h2) begin
                        if (cursor_col != 4'd0)  cursor_col <= cursor_col - 4'd1;
                        place_result <= 2'b00;
                    end else if (key_code == 4'h8) begin
                        if (cursor_col != 4'd15) cursor_col <= cursor_col + 4'd1;
                        place_result <= 2'b00;
                    end
                end

                /* 落子：若目前格子為空，則寫入並進入 pending_win_check */
                if (!pending_win_check && confirm_pulse) begin
                    if (current_cell_data == 2'b00) begin
                        place_en     <= 1'b1;
                        place_result <= 2'b01;

                        last_row     <= cursor_row;
                        last_col     <= cursor_col;
                        last_player  <= current_player;

                        pending_win_check <= 1'b1;
                    end else begin
                        place_result <= 2'b10;
                    end
                end
            end
        end
    end
endmodule


/* =============================================================================
 * module board_mem
 * 功能：棋盤記憶體（16x16）
 * 原理：
 *   - board[row][col] 保存棋子狀態：00空、01 P1、10 P2
 *   - cell_data 以組合方式回傳「游標位置」的格子內容
 *   - write_en 時若該格為空才寫入（避免覆蓋）
 * ============================================================================= */
module board_mem(
    input   clk,
    input   rst,
    input   write_en,
    input  [3:0] row,
    input  [3:0] col,
    input  [1:0] player,
    output [1:0] cell_data,
    output reg [1:0] board [0:15][0:15]
);

    integer i, j;

    assign cell_data = board[row][col];

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            for (i = 0; i < 16; i = i + 1)
                for (j = 0; j < 16; j = j + 1)
                    board[i][j] <= 2'b00;
        end else begin
            if (write_en) begin
                if (board[row][col] == 2'b00)
                    board[row][col] <= player;
            end
        end
    end
endmodule


/* =============================================================================
 * module win_checker
 * 功能：判斷是否達成五連（橫、豎、兩斜）
 * 原理：
 *   - 僅以最後一次落子 last_x/last_y 為中心檢查（效率高）
 *   - count_dir(dx,dy)：沿 (dx,dy) 方向往正向最多看 4 格、再往反向最多看 4 格
 *     連續同色就累加 count，任一方向 count>=5 即 win=1
 *
 * function in_range：
 *   - 用於確認索引仍在棋盤範圍內（0~15）
 *
 * task count_dir：
 *   - 執行「雙向延伸計數」並更新全域變數 count
 * ============================================================================= */
module win_checker(
    input  [1:0] board [0:15][0:15],
    input  [3:0] last_x,
    input  [3:0] last_y,
    input  [1:0] player,
    output reg   win
);
    integer count;

    function integer in_range;
        input integer x;
        input integer y;
        begin
            in_range = (x >= 0 && x < 16 && y >= 0 && y < 16);
        end
    endfunction

    task automatic count_dir;
        input integer dx;
        input integer dy;
        integer k;
        integer cx;
        integer cy;
        integer stop;
        begin
            count = 1;

            stop = 0;
            for (k = 1; k < 5; k = k + 1) begin
                if (!stop) begin
                    cx = last_x + dx * k;
                    cy = last_y + dy * k;
                    if (in_range(cx, cy) && board[cx][cy] == player)
                        count = count + 1;
                    else
                        stop = 1;
                end
            end

            stop = 0;
            for (k = 1; k < 5; k = k + 1) begin
                if (!stop) begin
                    cx = last_x - dx * k;
                    cy = last_y - dy * k;
                    if (in_range(cx, cy) && board[cx][cy] == player)
                        count = count + 1;
                    else
                        stop = 1;
                end
            end
        end
    endtask

    always @(*) begin
        win = 1'b0;
        count = 0;

        if (player != 2'b00) begin
            count_dir(1, 0);
            if (count >= 5) win = 1'b1;

            if (!win) begin
                count_dir(0, 1);
                if (count >= 5) win = 1'b1;
            end

            if (!win) begin
                count_dir(1, 1);
                if (count >= 5) win = 1'b1;
            end

            if (!win) begin
                count_dir(1, -1);
                if (count >= 5) win = 1'b1;
            end
        end
    end
endmodule


/* =============================================================================
 * module vga_display
 * 功能：VGA 640x480@60Hz 顯示產生器 + 棋盤繪圖
 * 原理：
 *   1) 依照 640x480 timing（總像素 800x525）產生 h_cnt/v_cnt 與 HS/VS
 *   2) visible 區域內輸出顏色，blanking 區域輸出黑色
 *   3) 在棋盤區域內：
 *        - 先畫格線（深綠）
 *        - 再畫棋子（P1 黑、P2 白）
 *        - 最上層畫游標（顏色依 current_player）
 *   4) 棋盤幾何：16x16，每格 28x28，共 448x448，置中於 640x480
 * ============================================================================= */
module vga_display(
    input  clk_vga,
    input  rst,
    input  [1:0] board [0:15][0:15],
    input  [3:0] cursor_row,
    input  [3:0] cursor_col,
    input  [1:0] current_player,
    output reg [3:0] VGA_R,
    output reg [3:0] VGA_G,
    output reg [3:0] VGA_B,
    output reg       VGA_HS,
    output reg       VGA_VS
);

    localparam H_VISIBLE = 640;
    localparam H_FRONT   = 16;
    localparam H_SYNC    = 96;
    localparam H_BACK    = 48;
    localparam H_TOTAL   = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;

    localparam V_VISIBLE = 480;
    localparam V_FRONT   = 10;
    localparam V_SYNC    = 2;
    localparam V_BACK    = 33;
    localparam V_TOTAL   = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

    reg [9:0] h_cnt;
    reg [9:0] v_cnt;

    wire visible = (h_cnt < H_VISIBLE) && (v_cnt < V_VISIBLE);

    localparam integer GRID_N     = 16;
    localparam integer CELL_SIZE  = 28;
    localparam integer BOARD_SIZE = GRID_N * CELL_SIZE;

    localparam integer X0 = (H_VISIBLE - BOARD_SIZE) / 2;
    localparam integer Y0 = (V_VISIBLE - BOARD_SIZE) / 2;

    localparam [3:0] BG_R = 4'hD, BG_G = 4'h9, BG_B = 4'h4;
    localparam [3:0] GRID_R = 4'h0, GRID_G = 4'h6, GRID_B = 4'h0;

    localparam integer STONE_SIZE = 20;
    localparam integer STONE_HALF = STONE_SIZE / 2;

    localparam integer CUR_THICK   = 2;
    localparam integer CROSS_LEN   = 6;
    localparam integer CROSS_THICK = 1;

    wire [3:0] CUR_R = (current_player == 2'b01) ? 4'h0 :
                       (current_player == 2'b10) ? 4'hF : 4'hF;
    wire [3:0] CUR_G = (current_player == 2'b01) ? 4'h0 :
                       (current_player == 2'b10) ? 4'hF : 4'h0;
    wire [3:0] CUR_B = (current_player == 2'b01) ? 4'h0 :
                       (current_player == 2'b10) ? 4'hF : 4'h0;

    wire in_board = (h_cnt >= X0) && (h_cnt < (X0 + BOARD_SIZE)) &&
                    (v_cnt >= Y0) && (v_cnt < (Y0 + BOARD_SIZE));

    wire [9:0] rel_x = h_cnt - X0;
    wire [9:0] rel_y = v_cnt - Y0;

    wire [3:0] cell_c = rel_x / CELL_SIZE;
    wire [3:0] cell_r = rel_y / CELL_SIZE;

    wire [5:0] in_x = rel_x % CELL_SIZE;
    wire [5:0] in_y = rel_y % CELL_SIZE;

    wire grid_pixel = (in_x == 0) || (in_y == 0) || (in_x == (CELL_SIZE-1)) || (in_y == (CELL_SIZE-1));

    wire [1:0] cell_value = board[cell_r][cell_c];
    wire cell_has_stone = (cell_value != 2'b00);

    localparam integer CX = CELL_SIZE / 2;
    localparam integer CY = CELL_SIZE / 2;

    wire in_stone_square =
        (in_x >= (CX - STONE_HALF)) && (in_x < (CX + STONE_HALF)) &&
        (in_y >= (CY - STONE_HALF)) && (in_y < (CY + STONE_HALF));

    wire is_cursor_cell = (cell_r == cursor_row) && (cell_c == cursor_col);

    wire cursor_outline_pixel =
        (in_x < CUR_THICK) || (in_y < CUR_THICK) ||
        (in_x >= (CELL_SIZE - CUR_THICK)) || (in_y >= (CELL_SIZE - CUR_THICK));

    wire cursor_cross_pixel =
        ((in_x >= (CX - CROSS_THICK)) && (in_x <= (CX + CROSS_THICK)) &&
         (in_y >= (CY - CROSS_LEN))   && (in_y <= (CY + CROSS_LEN))) ||
        ((in_y >= (CY - CROSS_THICK)) && (in_y <= (CY + CROSS_THICK)) &&
         (in_x >= (CX - CROSS_LEN))   && (in_x <= (CX + CROSS_LEN)));

    always @(posedge clk_vga or negedge rst) begin
        if (!rst) begin
            h_cnt  <= 10'd0;
            v_cnt  <= 10'd0;
            VGA_HS <= 1'b1;
            VGA_VS <= 1'b1;
        end else begin
            if (h_cnt == H_TOTAL-1) begin
                h_cnt <= 10'd0;
                if (v_cnt == V_TOTAL-1) v_cnt <= 10'd0;
                else v_cnt <= v_cnt + 10'd1;
            end else begin
                h_cnt <= h_cnt + 10'd1;
            end

            VGA_HS <= ~((h_cnt >= (H_VISIBLE + H_FRONT)) && (h_cnt < (H_VISIBLE + H_FRONT + H_SYNC)));
            VGA_VS <= ~((v_cnt >= (V_VISIBLE + V_FRONT)) && (v_cnt < (V_VISIBLE + V_FRONT + V_SYNC)));
        end
    end

    always @(*) begin
        VGA_R = 4'h0;
        VGA_G = 4'h0;
        VGA_B = 4'h0;

        if (visible) begin
            VGA_R = BG_R;
            VGA_G = BG_G;
            VGA_B = BG_B;

            if (in_board) begin
                if (grid_pixel) begin
                    VGA_R = GRID_R;
                    VGA_G = GRID_G;
                    VGA_B = GRID_B;
                end

                if (cell_has_stone && in_stone_square) begin
                    if (cell_value == 2'b01) begin
                        VGA_R = 4'h0;
                        VGA_G = 4'h0;
                        VGA_B = 4'h0;
                    end else begin
                        VGA_R = 4'hF;
                        VGA_G = 4'hF;
                        VGA_B = 4'hF;
                    end
                end

                if (is_cursor_cell && (cursor_outline_pixel || cursor_cross_pixel)) begin
                    VGA_R = CUR_R;
                    VGA_G = CUR_G;
                    VGA_B = CUR_B;
                end
            end
        end
    end

endmodule


/* =============================================================================
 * module dotmatrix_check
 * 功能：依 place_result 顯示圖示
 * place_result：
 *   - 01：顯示「圈」圖案
 *   - 10：顯示「叉」圖案
 * 其他：顯示空白
 * 原理：
 *   - 以 row_index 決定該列輸出的 8-bit pattern
 *   - dot_col 最後取反是因為常見 Dot Matrix 為 active-low 驅動
 * ============================================================================= */
module dotmatrix_check(
    input  [1:0] place_result,
    input  [2:0] row_index,
    output reg [7:0] dot_col
);

    reg [7:0] pattern;

    always @(*) begin
        pattern = 8'b00000000;
        if (place_result == 2'b01) begin
            case (row_index)
                3'd7: pattern = 8'b11111111;
                3'd6: pattern = 8'b11100111;
                3'd5: pattern = 8'b11011011;
                3'd4: pattern = 8'b10111101;
                3'd3: pattern = 8'b10111101;
                3'd2: pattern = 8'b11011011;
                3'd1: pattern = 8'b11100111;
                3'd0: pattern = 8'b11111111;
            endcase
        end else if (place_result == 2'b10) begin
            case (row_index)
                3'd7: pattern = 8'b11111111;
                3'd6: pattern = 8'b10111101;
                3'd5: pattern = 8'b11011011;
                3'd4: pattern = 8'b11100111;
                3'd3: pattern = 8'b11100111;
                3'd2: pattern = 8'b11011011;
                3'd1: pattern = 8'b10111101;
                3'd0: pattern = 8'b11111111;
            endcase
        end
        dot_col = ~pattern;
    end
endmodule


/* =============================================================================
 * module dotmatrix_winner
 * 功能：遊戲結束後顯示勝者圖案
 * winner：
 *   - 01：顯示 P1 圖案
 *   - 10：顯示 P2 圖案
 * 原理同 dotmatrix_check：row_index 對應 pattern，再做 active-low 反相
 * ============================================================================= */
module dotmatrix_winner(
    input        game_over,
    input  [1:0] winner,
    input  [2:0] row_index,
    output reg [7:0] dot_col
);

    reg [7:0] pattern;

    always @(*) begin
        pattern = 8'b00000000;
        if (game_over) begin
            if (winner == 2'b01) begin
                case (row_index)
                    3'd7: pattern = 8'b11110011;
                    3'd6: pattern = 8'b11100011;
                    3'd5: pattern = 8'b11000011;
                    3'd4: pattern = 8'b11110011;
                    3'd3: pattern = 8'b11110011;
                    3'd2: pattern = 8'b11110011;
                    3'd1: pattern = 8'b11000001;
                    3'd0: pattern = 8'b11111111;
                endcase
            end else if (winner == 2'b10) begin
                case (row_index)
                    3'd7: pattern = 8'b11100011;
                    3'd6: pattern = 8'b11001101;
                    3'd5: pattern = 8'b11111001;
                    3'd4: pattern = 8'b11110011;
                    3'd3: pattern = 8'b11100111;
                    3'd2: pattern = 8'b11001111;
                    3'd1: pattern = 8'b11000001;
                    3'd0: pattern = 8'b11111111;
                endcase
            end
        end
        dot_col = ~pattern;
    end
endmodule


/* =============================================================================
 * module sevenseg_digit
 * 功能：7段顯示器數字解碼（0~9）
 * 原理：
 *   - 輸入 digit（0~9）
 *   - 輸出 seg（常見為 active-low 的 7 段碼）
 * ============================================================================= */
module sevenseg_digit(
    input  [3:0] digit,
    output reg [6:0] seg
);
    always @(*) begin
        case (digit)
            4'd0: seg = 7'b1000000;
            4'd1: seg = 7'b1111001;
            4'd2: seg = 7'b0100100;
            4'd3: seg = 7'b0110000;
            4'd4: seg = 7'b0011001;
            4'd5: seg = 7'b0010010;
            4'd6: seg = 7'b0000010;
            4'd7: seg = 7'b1111000;
            4'd8: seg = 7'b0000000;
            4'd9: seg = 7'b0010000;
            default: seg = 7'b1111111;
        endcase
    end
endmodule


/* =============================================================================
 * module turn_timer
 * 功能：回合倒數計時器（以 50MHz 推進秒）
 * 原理：
 *   - count 從 0 計到 secClock-1（secClock=50,000,000）代表 1 秒
 *   - 每過 1 秒 sec_left 減 1
 *   - reset_pulse 時重置 count 並把 sec_left 重新載入 seconds
 *   - timeout_pulse：在 sec_left 從 1 要變 0 的那一秒輸出一次脈衝
 * ============================================================================= */
module turn_timer(
    input        clk,
    input        rst,
    input        enable,
    input        reset_pulse,
    output reg [6:0] sec_left,
    output reg       timeout_pulse
);
    localparam integer secClock = 50000000;
    localparam [6:0] seconds = 7'd99;

    reg [31:0] count;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            count <= 32'd0;
            sec_left <= seconds;
            timeout_pulse <= 1'b0;
        end else begin
            timeout_pulse <= 1'b0;

            if (reset_pulse) begin
                count <= 32'd0;
                sec_left <= seconds;
            end else if (enable) begin
                if (count == (secClock - 1)) begin
                    count <= 32'd0;

                    if (sec_left != 7'd0) begin
                        sec_left <= sec_left - 7'd1;

                        if (sec_left == 7'd1) begin
                            timeout_pulse <= 1'b1;
                        end
                    end
                end else begin
                    count <= count + 32'd1;
                end
            end
        end
    end
endmodule


/* =============================================================================
 * module keypad_onepress_cdc
 * 功能：把 KeyPad 的「長按」變成「每次按下只出一次事件」，並完成跨時脈同步
 * 參數：
 *   RELEASE_TH：判定「已放開」需要連續看到 raw_valid=0 的次數門檻
 *
 * 原理（clk_scan 域）：
 *   - held=0：尚未按住，若 raw_valid=1 => 鎖存 raw_code 並翻轉 evt_tgl
 *   - held=1：表示正在按住；若 raw_valid=0 就累計 miss_cnt
 *            miss_cnt >= RELEASE_TH 視為放開，held 回到 0
 *
 * 原理（clk 域）：
 *   - 3-bit shift 同步 evt_tgl，利用 XOR 偵測 toggle 變化形成 evt_pulse_raw
 *   - code_latched 也用兩級 FF 同步到 clk 域，evt_pulse_raw 當拍輸出 key_valid=1
 * ============================================================================= */
module keypad_onepress_cdc #(
    parameter [2:0] RELEASE_TH = 3'd6
)(
    input        clk_scan,
    input        clk,
    input        rst,

    input        raw_valid,
    input  [3:0] raw_code,

    output       key_valid,
    output [3:0] key_code
);

    reg        held;
    reg [2:0]  miss_cnt;
    reg [3:0]  code_latched;
    reg        evt_tgl;

    always @(posedge clk_scan or negedge rst) begin
        if (!rst) begin
            held         <= 1'b0;
            miss_cnt     <= 3'd0;
            code_latched <= 4'd0;
            evt_tgl      <= 1'b0;
        end else begin
            if (!held) begin
                if (raw_valid) begin
                    held         <= 1'b1;
                    miss_cnt     <= 3'd0;
                    code_latched <= raw_code;
                    evt_tgl      <= ~evt_tgl;
                end
            end else begin
                if (raw_valid) begin
                    miss_cnt <= 3'd0;
                end else begin
                    if (miss_cnt < RELEASE_TH)
                        miss_cnt <= miss_cnt + 3'd1;
                end

                if (miss_cnt >= RELEASE_TH) begin
                    held     <= 1'b0;
                    miss_cnt <= 3'd0;
                end
            end
        end
    end

    reg [2:0] tgl_sync;
    always @(posedge clk or negedge rst) begin
        if (!rst) tgl_sync <= 3'b000;
        else      tgl_sync <= {tgl_sync[1:0], evt_tgl};
    end

    wire evt_pulse_raw = tgl_sync[2] ^ tgl_sync[1];

    reg [3:0] code_sync1, code_sync2;
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            code_sync1 <= 4'd0;
            code_sync2 <= 4'd0;
        end else begin
            code_sync1 <= code_latched;
            code_sync2 <= code_sync1;
        end
    end

    reg [3:0] key_code_reg;
    reg       key_valid_reg;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            key_code_reg  <= 4'd0;
            key_valid_reg <= 1'b0;
        end else begin
            key_valid_reg <= evt_pulse_raw;
            if (evt_pulse_raw) begin
                key_code_reg <= code_sync2;
            end
        end
    end

    assign key_valid = key_valid_reg;
    assign key_code  = key_code_reg;

endmodule
