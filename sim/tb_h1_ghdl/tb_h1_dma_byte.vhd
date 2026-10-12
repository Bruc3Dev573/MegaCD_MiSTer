-- Checks that a restore clears DMA_BYTE in the ASIC host-read path.
--
-- Drives the ASIC and CDC entities through their savestate interfaces only.
-- No CPU bus is instantiated.
--
-- A mid-word save must be refused. After a restore of image bytes the first
-- completed HD word must match the image. A second restore checks the held
-- CDD_REC edge. Failures stop the run at severity failure. Each check reports PASS.
--
-- Run: bash sim/run_smoke.sh asic

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library work;
use work.ASIC_PKG.all;

entity tb_h1_dma_byte is end entity tb_h1_dma_byte;

architecture sim of tb_h1_dma_byte is

    constant T   : time := 10 ns;

    signal CLK   : std_logic := '0';
    signal RST_N : std_logic := '0';

    -- ASIC SS interface
    signal asic_ss_addr    : std_logic_vector(7 downto 0)  := (others => '0');
    signal asic_ss_wr_data : std_logic_vector(31 downto 0) := (others => '0');
    signal asic_ss_wr_en   : std_logic := '0';
    signal asic_ss_rd_data : std_logic_vector(31 downto 0);
    signal asic_ss_freeze  : std_logic := '0';
    signal asic_ss_quiet   : std_logic;
    signal asic_ss_quiet_bits : std_logic_vector(13 downto 0);

    -- CDC handshake
    signal cdc_hdi    : std_logic_vector(7 downto 0);
    signal cdc_hrd_n  : std_logic;
    signal cdc_dten_n : std_logic;
    signal cdc_wait_n : std_logic;

    -- ASIC unused outputs (sinks)
    signal s68k_do      : std_logic_vector(15 downto 0);
    signal ext_vdo      : std_logic_vector(15 downto 0);
    signal ext_dtack_n  : std_logic;
    signal s68k_dtack_n : std_logic;
    signal s68k_ipl_n   : std_logic_vector(2 downto 0);
    signal s68k_vpa_n   : std_logic;
    signal s68k_halt_n  : std_logic;
    signal s68k_reset_n : std_logic;
    signal s68k_ce_f    : std_logic;
    signal s68k_ce_r    : std_logic;
    signal prg_a        : std_logic_vector(17 downto 0);
    signal prg_do       : std_logic_vector(15 downto 0);
    signal prg_wrl_n    : std_logic;
    signal prg_wrh_n    : std_logic;
    signal prg_oe_n     : std_logic;
    signal prg_rfs      : std_logic;
    signal pcm_a        : std_logic_vector(12 downto 0);
    signal pcm_di_s     : std_logic_vector(7 downto 0);
    signal pcm_we_n     : std_logic;
    signal pcm_n_s      : std_logic;
    signal rom_ce_n     : std_logic;
    signal pram_n       : std_logic;
    signal bram_n       : std_logic;
    signal brom_n       : std_logic;
    signal cdc_n_s      : std_logic;
    signal coe_n        : std_logic;
    signal clwe_n       : std_logic;
    signal cuwe_n       : std_logic;
    signal eres_n       : std_logic;
    signal cdd_comm     : std_logic_vector(39 downto 0);
    signal cdd_send     : std_logic;
    signal cdd_stat_in  : std_logic_vector(39 downto 0) := (others => '0');
    signal cdd_rec_in   : std_logic := '0';
    signal wram0_a      : std_logic_vector(15 downto 0);
    signal wram0_do     : std_logic_vector(15 downto 0);
    signal wram0_wr     : std_logic;
    signal wram1_a      : std_logic_vector(15 downto 0);
    signal wram1_do     : std_logic_vector(15 downto 0);
    signal wram1_wr     : std_logic;
    signal fd_dat       : std_logic_vector(10 downto 0);
    signal fd_wr        : std_logic;
    signal led_r        : std_logic;
    signal led_g        : std_logic;

    -- CDC savestate interface and RAM model
    signal cdc_do       : std_logic_vector(7 downto 0);
    signal cdc_ss_addr  : std_logic_vector(5 downto 0)  := (others => '0');
    signal cdc_ss_wr_data : std_logic_vector(31 downto 0) := (others => '0');
    signal cdc_ss_wr_en : std_logic := '0';
    signal cdc_ss_rd_data : std_logic_vector(31 downto 0);
    signal cdc_ss_quiet : std_logic;
    signal cdc_ss_freeze: std_logic := '0';
    signal cdc_ss_head  : std_logic_vector(23 downto 0);
    signal cdc_ss_dbg   : std_logic_vector(15 downto 0);
    signal cdc_ram_di   : std_logic_vector(7 downto 0) := x"BE";
    signal cdc_ram_a_wr : std_logic_vector(15 downto 1);
    signal cdc_ram_a_rd : std_logic_vector(15 downto 0);
    signal cdc_ram_do   : std_logic_vector(15 downto 0);
    signal cdc_ram_we   : std_logic;
    signal cdc_int_n_out: std_logic;

    -- Combined quiet
    signal mcd_quiet    : std_logic;

    -- Image stream (4 words)
    type byte8_t is array(0 to 7) of std_logic_vector(7 downto 0);
    constant IMG_BYTES : byte8_t :=
        (x"00", x"01", x"00", x"02", x"00", x"03", x"00", x"04");

    type word4_t is array(0 to 3) of std_logic_vector(15 downto 0);
    constant IMG_WORDS : word4_t :=
        (x"0001", x"0002", x"0003", x"0004");

    -- HD capture
    signal hd_captured  : word4_t := (others => (others => '0'));
    signal hd_count     : integer := 0;
    signal prev_hd_snap : std_logic_vector(15 downto 0) := x"FFFF";
    signal capture_enable : std_logic := '0';
    signal image_mode : std_logic := '0';

begin

    CLK <= not CLK after T/2;

    mcd_quiet <= asic_ss_quiet and cdc_ss_quiet;

    ---------------------------------------------------------------------------
    -- ASIC instance
    ---------------------------------------------------------------------------
    u_asic : entity work.ASIC
        port map (
            CLK => CLK,  RST_N => RST_N,  ENABLE => '1',  CLK50_EN => '1',
            S68K_A      => (others => '0'), S68K_DI     => (others => '0'),
            S68K_DO     => s68k_do,         S68K_AS_N   => '1',
            S68K_RNW    => '1',             S68K_UDS_N  => '1',
            S68K_LDS_N  => '1',
            S68K_DTACK_N => s68k_dtack_n,  S68K_IPL_N  => s68k_ipl_n,
            S68K_VPA_N  => s68k_vpa_n,     S68K_FC     => (others => '0'),
            S68K_HALT_N => s68k_halt_n,    S68K_RESET_N => s68k_reset_n,
            S68K_CE_F   => s68k_ce_f,      S68K_CE_R   => s68k_ce_r,
            EXT_VA      => (others => '0'), EXT_VDI     => (others => '0'),
            EXT_VDO     => ext_vdo,         EXT_AS_N    => '1',
            EXT_RNW     => '1',             EXT_UDS_N   => '1',
            EXT_LDS_N   => '1',
            EXT_DTACK_N => ext_dtack_n,     EXT_ASEL_N  => '1',
            EXT_VCLK_CE => '0',            EXT_RAS2_N  => '1',
            EXT_ROM_N   => '1',            EXT_FDC_N   => '1',
            PRG_A       => prg_a,           PRG_DI      => (others => '0'),
            PRG_DO      => prg_do,          PRG_WRL_N   => prg_wrl_n,
            PRG_WRH_N   => prg_wrh_n,      PRG_OE_N    => prg_oe_n,
            PRG_RFS     => prg_rfs,         PRG_RDY     => '1',
            PCM_A       => pcm_a,           PCM_DI      => pcm_di_s,
            PCM_WE_N    => pcm_we_n,        PCM_N       => pcm_n_s,
            ROM_DI      => (others => '0'), ROM_CE_N    => rom_ce_n,
            ROM_RDY     => '1',
            PRAM_N      => pram_n,          BRAM_N      => bram_n,
            BROM_N      => brom_n,          CDC_N       => cdc_n_s,
            COE_N       => coe_n,           CLWE_N      => clwe_n,
            CUWE_N      => cuwe_n,          CDC_INT_N   => '1',
            ERES_N      => eres_n,
            CDC_HDI     => cdc_hdi,         CDC_HRD_N   => cdc_hrd_n,
            CDC_DTEN_N  => cdc_dten_n,      CDC_WAIT_N  => cdc_wait_n,
            CD_DI       => (others => '0'), CD_SC_WR    => '0',
            CDD_STAT    => cdd_stat_in,      CDD_COMM    => cdd_comm,
            CDD_SEND    => cdd_send,         CDD_REC     => cdd_rec_in,
            CDD_DM      => '0',
            WORDRAM0_A  => wram0_a,  WORDRAM0_DI => (others => '0'),
            WORDRAM0_DO => wram0_do, WORDRAM0_WR => wram0_wr,
            WORDRAM1_A  => wram1_a,  WORDRAM1_DI => (others => '0'),
            WORDRAM1_DO => wram1_do, WORDRAM1_WR => wram1_wr,
            FD_DAT      => fd_dat,   FD_WR       => fd_wr,
            LED_RED     => led_r,    LED_GREEN   => led_g,
            SS_ADDR     => asic_ss_addr,
            SS_WR_DATA  => asic_ss_wr_data,
            SS_WR_EN    => asic_ss_wr_en,
            SS_RD_DATA  => asic_ss_rd_data,
            SS_FREEZE   => asic_ss_freeze,
            SS_QUIET    => asic_ss_quiet,
            SS_QUIET_BITS => asic_ss_quiet_bits);

    ---------------------------------------------------------------------------
    -- CDC instance
    ---------------------------------------------------------------------------
    u_cdc : entity work.CDC
        port map (
            CLK     => CLK,  RESET_N => RST_N,
            ENABLE  => '1',  PALSW => '0',  CLKEN_P => '1',  CLKEN_N => '1',
            DI      => (others => '0'),  DO  => cdc_do,
            CS_N    => '1',  RS => '0',  RD_N => '1',  WR_N => '1',
            INT_N   => cdc_int_n_out,
            HDO     => cdc_hdi,     HRD_N   => cdc_hrd_n,
            DTEN_N  => cdc_dten_n,  WAIT_N  => cdc_wait_n,
            CD_DI   => (others => '0'),  CD_WR => '0',
            RAM_A_WR => cdc_ram_a_wr,  RAM_A_RD => cdc_ram_a_rd,
            RAM_DI  => cdc_ram_di,
            RAM_DO  => cdc_ram_do,  RAM_WE  => cdc_ram_we,
            SS_ADDR     => cdc_ss_addr,
            SS_WR_DATA  => cdc_ss_wr_data,
            SS_WR_EN    => cdc_ss_wr_en,
            SS_RD_DATA  => cdc_ss_rd_data,
            SS_QUIET    => cdc_ss_quiet,
            SS_FREEZE   => cdc_ss_freeze,
            SS_HEAD_MSF => cdc_ss_head,
            SS_DBG      => cdc_ss_dbg);

    ---------------------------------------------------------------------------
    -- HD capture: poll SS_RD_DATA@x02 for new HD words
    ---------------------------------------------------------------------------
    hd_cap : process(CLK)
    begin
        if rising_edge(CLK) then
            if capture_enable = '0' then
                prev_hd_snap <= asic_ss_rd_data(15 downto 0);
            elsif asic_ss_addr = x"02" then
                if asic_ss_rd_data(15 downto 0) /= prev_hd_snap and
                   asic_ss_rd_data(15 downto 0) /= x"0000" and
                   asic_ss_rd_data(15 downto 0) /= x"FFFF" and
                   hd_count < 4 then
                    hd_captured(hd_count) <= asic_ss_rd_data(15 downto 0);
                    hd_count <= hd_count + 1;
                end if;
                prev_hd_snap <= asic_ss_rd_data(15 downto 0);
            end if;
        end if;
    end process hd_cap;

    ---------------------------------------------------------------------------
    -- RAM model: returns image bytes indexed by the CDC DAC on cdc_ram_a_rd.
    -- Before the restore it returns the stale byte x"BE".
    ---------------------------------------------------------------------------
    ram_oracle : process(all)
    begin
        if image_mode = '0' then
            cdc_ram_di <= x"BE";
        else
            case to_integer(unsigned(cdc_ram_a_rd(2 downto 0))) is
                when 0 => cdc_ram_di <= IMG_BYTES(0);
                when 1 => cdc_ram_di <= IMG_BYTES(1);
                when 2 => cdc_ram_di <= IMG_BYTES(2);
                when 3 => cdc_ram_di <= IMG_BYTES(3);
                when 4 => cdc_ram_di <= IMG_BYTES(4);
                when 5 => cdc_ram_di <= IMG_BYTES(5);
                when 6 => cdc_ram_di <= IMG_BYTES(6);
                when 7 => cdc_ram_di <= IMG_BYTES(7);
                when others => cdc_ram_di <= x"00";
            end case;
        end if;
    end process ram_oracle;

    ---------------------------------------------------------------------------
    -- Stimulus
    ---------------------------------------------------------------------------
    stim : process
        variable quiet_fired_mid : boolean := false;  -- combined quiet at DMA_BYTE=1

        procedure wclk(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(CLK);
            end loop;
        end procedure;

        procedure asic_ss_wr(addr : std_logic_vector(7 downto 0);
                              data : std_logic_vector(31 downto 0)) is
        begin
            asic_ss_addr <= addr;  asic_ss_wr_data <= data;
            asic_ss_wr_en <= '1';  wclk(1);
            asic_ss_wr_en <= '0';  wclk(1);
        end procedure;

        procedure cdc_ss_wr(addr : std_logic_vector(5 downto 0);
                             data : std_logic_vector(31 downto 0)) is
        begin
            cdc_ss_addr <= addr;  cdc_ss_wr_data <= data;
            cdc_ss_wr_en <= '1';  wclk(1);
            cdc_ss_wr_en <= '0';  wclk(1);
        end procedure;

    begin
        -- Reset
        RST_N <= '0';  wclk(4);
        RST_N <= '1';  wclk(4);

        -----------------------------------------------------------------------
        -- Phase 1: inject state
        -----------------------------------------------------------------------
        -- ASIC SS_ADDR=x00: DS=DS_IDLE, DMA_BYTE=0
        asic_ss_wr(x"00", x"00000000");

        -- ASIC SS_ADDR=x01: DD=010 (host-read, bits[10:8]=2)
        -- w1 encoding (ASIC.vhd:660): "0000000" & DOT & LN & SC1 & SC0 & DD & WP
        -- DD is bits[10:8], rest zero
        asic_ss_wr(x"01", x"00000200");

        -- CDC SS_ADDR="000000": CTRL0=0, IFSTAT=x02 with DTEN=1, IFCTRL=x02 with DOUTEN=1, AR=0.
        -- Layout is CTRL0[31:24] IFSTAT[23:16] IFCTRL[15:8] "0000" AR[3:0].
        cdc_ss_wr("000000", x"00020200");

        -- CDC SS_ADDR="000010": DBC=16 (8 words), DAC=0
        cdc_ss_wr("000010", x"00000010");

        -- CDC SS_ADDR="000110": DT_EN=1 at bit29, DEC_WR=0
        -- From CDC.vhd:249: "0" & CD_WR_OLD & DT_EN & DEC_WR & DEC_WR_EN & WORD_CNT & DEC_DAT
        -- bit31=0, bit30=0, bit29=DT_EN=1
        cdc_ss_wr("000110", x"20000000");

        wclk(2);

        -----------------------------------------------------------------------
        -- Phase 2: stop at the exact coupled mid-word boundary.
        -- First HRD_N low/high consumes the high byte. The next CDC SEND_WAIT
        -- stages the low byte while ASIC is DS_IDLE with DMA_BYTE=1.
        asic_ss_addr <= x"01";
        quiet_fired_mid := false;
        for cyc in 0 to 50 loop
            wclk(1);
            if cdc_hrd_n = '0' then
                quiet_fired_mid := true;
                exit;
            end if;
        end loop;
        assert quiet_fired_mid report "FAIL: ASIC never requested first CDC byte"
            severity failure;
        quiet_fired_mid := false;
        for cyc in 0 to 20 loop
            wclk(1);
            if cdc_hrd_n = '1' then
                quiet_fired_mid := true;
                exit;
            end if;
        end loop;
        assert quiet_fired_mid report "FAIL: first CDC byte was never consumed"
            severity failure;
        quiet_fired_mid := false;
        for cyc in 0 to 20 loop
            wclk(1);
            if cdc_ss_quiet = '1' and cdc_wait_n = '1' then
                quiet_fired_mid := true;
                exit;
            end if;
        end loop;
        assert quiet_fired_mid report "FAIL: CDC never staged the low byte"
            severity failure;
        assert asic_ss_quiet_bits(0) = '0'
            report "FAIL: SS_QUIET accepts DMA_BYTE=1 mid-word" severity failure;
        assert mcd_quiet = '0'
            report "FAIL: combined quiet grants a mid-word save" severity failure;

        -----------------------------------------------------------------------
        -- Phase 3: freeze and restore
        -----------------------------------------------------------------------
        asic_ss_freeze <= '1';  cdc_ss_freeze <= '1';
        wclk(2);

        -- Restore the ASIC. This clears DMA_BYTE and DMA_DAT.
        asic_ss_wr(x"00", x"00000000");
        -- HD is an image register too. Set a sentinel so the monitor cannot
        -- mistake the pre-load machine's completed stale word for post-load data.
        asic_ss_wr(x"02", x"0000FFFF");

        -- The restored staged word is still active with DTEN=0 and DTBSY=0 in IFSTAT
        -- and DOUTEN=1 in IFCTRL. Address x08 below re-enters TS_SEND_WAIT.
        cdc_ss_wr("000000", x"00000200");

        -- The FIFO holds byte 0 and DAC already points to the next unread byte.
        cdc_ss_wr("000010", x"00010008");

        -- Restore DT_EN=1
        cdc_ss_wr("000110", x"20000000");

        -- Restore FIFO_DATA0 with the first image byte. The valid bit enters TS_SEND_WAIT.
        -- FIFO_DATA0[8:0] = "1" & IMG_BYTES(0) = "1_0000_0000" = 0x100
        cdc_ss_wr("001000", x"00000100");
        image_mode <= '1';

        asic_ss_freeze <= '0';  cdc_ss_freeze <= '0';
        wclk(2);

        -----------------------------------------------------------------------
        -- Phase 4: drive image stream, observe HD
        -----------------------------------------------------------------------
        -- Switch SS read mux to HD register
        asic_ss_addr <= x"02";
        capture_enable <= '1';

        for cyc in 0 to 199 loop
            wclk(1);
            if hd_count >= 4 then
                exit;
            end if;
        end loop;

        wclk(10);

        -----------------------------------------------------------------------
        -- Phase 5: check results
        -----------------------------------------------------------------------
        -- No CPU bus is instantiated, so DS_WRITE_WAIT stops after one host word.
        -- That first word shows whether the restore shifted the stream by a byte.
        assert hd_count >= 1
            report "FAIL: no post-restore HD word captured" severity failure;
        assert hd_captured(0) = IMG_WORDS(0)
            report "FAIL HD[0]: got 0x" & to_hstring(hd_captured(0)) &
                   ", expected 0x0001. The high byte is stale or the stream is shifted by one byte."
            severity failure;

        report "PASS: HD[0]=0x0001 and the mid-word save was refused";

        -----------------------------------------------------------------------
        -- Phase 6: CDD_REC edge latch must be canonical across a second load.
        -----------------------------------------------------------------------
        RST_N <= '0'; cdd_rec_in <= '0'; wclk(4);
        RST_N <= '1'; wclk(4);
        -- Restore HOCK=1, then consume one old status so that CDD_REC_OLD=1 and
        -- CDD_STAT_RECEIVED=0, the condition inherited from before the load.
        asic_ss_wr(x"00", x"00400000");
        cdd_stat_in <= x"1111111111";
        cdd_rec_in <= '1';
        wclk(3);
        asic_ss_freeze <= '1';
        wclk(1);
        -- The restore sets CDD_REC_OLD=0 and keeps HOCK=1.
        asic_ss_wr(x"00", x"00400000");
        cdd_stat_in <= x"123456789A";
        wclk(1);
        asic_ss_freeze <= '0';
        wclk(3);
        asic_ss_addr <= x"30"; wclk(1);
        assert asic_ss_rd_data = x"3456789A"
            report "FAIL: held post-load CDD_REC pulse was lost (status low32)"
            severity failure;
        asic_ss_addr <= x"31"; wclk(1);
        assert asic_ss_rd_data(7 downto 0) = x"12"
            report "FAIL: held post-load CDD_REC pulse was lost (status high8)"
            severity failure;
        report "PASS: restore re-arms held CDD_REC edge and captures forced status";

        std.env.finish;
    end process stim;

end architecture sim;
