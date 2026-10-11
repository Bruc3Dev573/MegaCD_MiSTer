-- Checks the CDC host-transfer restore for a stale valid byte and for a staged word.
--
-- FIFO_DATA0(8) is set when a byte is fetched for the host and stays set when
-- the host reads it. Only DTTRG, clearing DOUTEN or reset clear it. A state
-- saved between the end of a transfer and the next DTTRG therefore holds
-- valid=1 with DTBSY=1 in IFSTAT.
--
-- Case A restores a finished transfer with valid=1 and then issues DTTRG.
--    The engine must fetch from the buffer: DTEN_N goes low and the first
--    byte is RAM[DAC].
-- Case B restores a busy transfer with DTBSY=0 and a staged byte. The host must
--    get the staged byte first, then RAM[DAC].
--
-- Each case reports ok or FAIL. The run ends with PASS, or FAIL at severity failure.
--
-- Run: bash sim/run_smoke.sh cdc

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_cdc_stale_valid is end entity;

architecture sim of tb_cdc_stale_valid is
	constant T : time := 10 ns;
	signal CLK     : std_logic := '0';
	signal RESET_N : std_logic := '0';
	signal DI      : std_logic_vector(7 downto 0) := (others => '0');
	signal DO      : std_logic_vector(7 downto 0);
	signal CS_N, RS, RD_N, WR_N : std_logic := '1';
	signal INT_N   : std_logic;
	signal HDO     : std_logic_vector(7 downto 0);
	signal HRD_N   : std_logic := '1';
	signal DTEN_N, WAIT_N : std_logic;
	signal RAM_A_WR : std_logic_vector(15 downto 1);
	signal RAM_A_RD : std_logic_vector(15 downto 0);
	signal RAM_DI   : std_logic_vector(7 downto 0);
	signal RAM_DO   : std_logic_vector(15 downto 0);
	signal RAM_WE   : std_logic;
	signal SS_ADDR    : std_logic_vector(5 downto 0) := (others => '0');
	signal SS_WR_DATA : std_logic_vector(31 downto 0) := (others => '0');
	signal SS_WR_EN   : std_logic := '0';
	signal SS_RD_DATA : std_logic_vector(31 downto 0);
	signal SS_QUIET   : std_logic;
	signal SS_HEAD    : std_logic_vector(23 downto 0);
	signal SS_DBG     : std_logic_vector(15 downto 0);
	signal SS_FREEZE  : std_logic := '0';

	function pat(a : std_logic_vector(15 downto 0)) return std_logic_vector is
	begin
		return a(7 downto 0) xor x"A5";
	end function;
begin
	CLK <= not CLK after T / 2;
	RAM_DI <= pat(RAM_A_RD);

	dut : entity work.CDC port map(
		CLK => CLK, RESET_N => RESET_N, ENABLE => '1', CLKEN_P => '1', CLKEN_N => '0',
		DI => DI, DO => DO, CS_N => CS_N, RS => RS, RD_N => RD_N, WR_N => WR_N, INT_N => INT_N,
		HDO => HDO, HRD_N => HRD_N, DTEN_N => DTEN_N, WAIT_N => WAIT_N,
		CD_DI => (others => '0'), CD_WR => '0',
		RAM_A_WR => RAM_A_WR, RAM_A_RD => RAM_A_RD, RAM_DI => RAM_DI, RAM_DO => RAM_DO, RAM_WE => RAM_WE,
		SS_ADDR => SS_ADDR, SS_WR_DATA => SS_WR_DATA, SS_WR_EN => SS_WR_EN, SS_RD_DATA => SS_RD_DATA,
		SS_QUIET => SS_QUIET, SS_FREEZE => SS_FREEZE, SS_HEAD_MSF => SS_HEAD, SS_DBG => SS_DBG);

	process
		procedure ss_wr(a : std_logic_vector(5 downto 0); d : std_logic_vector(31 downto 0)) is
		begin
			SS_ADDR <= a; SS_WR_DATA <= d; SS_WR_EN <= '1';
			wait until rising_edge(CLK);
			SS_WR_EN <= '0';
			wait until rising_edge(CLK);
		end procedure;

		procedure reg_wr(rs_v : std_logic; d : std_logic_vector(7 downto 0)) is
		begin
			CS_N <= '0'; RS <= rs_v; DI <= d; WR_N <= '0';
			wait until rising_edge(CLK); wait until rising_edge(CLK);
			WR_N <= '1'; CS_N <= '1';
			wait until rising_edge(CLK); wait until rising_edge(CLK);
		end procedure;

		-- The ASIC's read (ASIC.vhd DS_IDLE/DS_CDC_READ): wait for DTEN_N low and
		-- WAIT_N high, raise the read, sample HDO once the CDC drops WAIT_N.
		procedure host_read(v : out std_logic_vector(7 downto 0); ok : out boolean) is
		begin
			ok := false;
			for i in 0 to 200 loop
				if DTEN_N = '0' and WAIT_N = '1' then
					ok := true;
					exit;
				end if;
				wait until rising_edge(CLK);
			end loop;
			if not ok then
				return;
			end if;
			HRD_N <= '0';
			ok := false;
			for i in 0 to 200 loop
				wait until rising_edge(CLK);
				if WAIT_N = '0' then
					ok := true;
					exit;
				end if;
			end loop;
			v := HDO;
			HRD_N <= '1';
			wait until rising_edge(CLK);
			wait until rising_edge(CLK);
		end procedure;

		procedure restore(ifstat : std_logic_vector(7 downto 0); dac, dbc : std_logic_vector(15 downto 0);
		                  fifo : std_logic_vector(8 downto 0)) is
		begin
			-- The engine restores with the machine frozen, as in the core.
			-- CTRL0=A7, IFCTRL=3A with DOUTEN set, AR=8. Words go in engine order 0, 2, 6, 8.
			SS_FREEZE <= '1';
			wait until rising_edge(CLK);
			ss_wr("000000", x"A7" & ifstat & x"3A" & x"08");
			ss_wr("000010", dac & dbc);
			ss_wr("000110", x"28000000");   -- DT_EN=1, DEC_WR_EN=1
			ss_wr("001000", x"00000" & "000" & fifo);
			SS_FREEZE <= '0';
			wait until rising_edge(CLK);
		end procedure;

		variable v : std_logic_vector(7 downto 0);
		variable ok : boolean;
		variable fails : integer := 0;
	begin
		wait for 5 * T;
		RESET_N <= '1';
		wait for 5 * T;

		-- Case A: finished transfer with DTBSY=1, DTEN=1, DBC=FFF and stale valid byte 0x55.
		restore(x"FF", x"1344", x"0FFF", "1" & x"55");
		wait for 10 * T;
		reg_wr('0', x"06");   -- AR = DTTRG
		reg_wr('1', x"00");   -- DTTRG
		host_read(v, ok);
		if not ok then
			report "A FAIL: DTEN_N never fell after DTTRG (engine parked in SEND_WAIT)" severity error;
			fails := fails + 1;
		elsif v /= pat(x"1344") then
			report "A FAIL: first byte " & to_hstring(v) & ", expected RAM[DAC]=" & to_hstring(pat(x"1344"))
				severity error;
			fails := fails + 1;
		else
			report "A ok: first byte after DTTRG = RAM[DAC] " & to_hstring(v);
		end if;

		-- Case B: transfer in progress with DTBSY=0, DTEN=0 and staged byte 0xC8.
		RESET_N <= '0'; wait for 3 * T; RESET_N <= '1'; wait for 3 * T;
		restore(x"F5", x"2000", x"07FF", "1" & x"C8");
		host_read(v, ok);
		if not ok or v /= x"C8" then
			report "B FAIL: first byte " & to_hstring(v) & ", expected staged C8" severity error;
			fails := fails + 1;
		else
			host_read(v, ok);
			if not ok or v /= pat(x"2000") then
				report "B FAIL: second byte " & to_hstring(v) & ", expected RAM[DAC]=" & to_hstring(pat(x"2000"))
					severity error;
				fails := fails + 1;
			else
				report "B ok: staged byte C8, then RAM[DAC] " & to_hstring(v);
			end if;
		end if;

		if fails = 0 then
			report "PASS" severity note;
		else
			report "FAIL (" & integer'image(fails) & ")" severity failure;
		end if;
		std.env.finish;
	end process;
end architecture;
