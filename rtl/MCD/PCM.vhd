library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library STD;
use IEEE.NUMERIC_STD.ALL;

entity PCM is
	port(
		CLK			: in std_logic;
		RST_N			: in std_logic;
		ENABLE		: in std_logic;
		CLKEN 		: in std_logic;
		
		PALSW			: in std_logic;
		
		A				: in std_logic_vector(12 downto 0);
		DI				: in std_logic_vector(7 downto 0);
		DO				: out std_logic_vector(7 downto 0);
		CS_N			: in std_logic;
		RD_N			: in std_logic;
		WR_N			: in std_logic;
		
		RAM_ADDR_A 	: out std_logic_vector(15 downto 0);
		RAM_DI_A		: in std_logic_vector(7 downto 0);
		RAM_DO_A		: out std_logic_vector(7 downto 0);
		RAM_WE_A		: out std_logic;
		RAM_ADDR_B  : out std_logic_vector(15 downto 0);
		RAM_DI_B		: in std_logic_vector(7 downto 0);
		
		SL				: out signed(15 downto 0);
		SR				: out signed(15 downto 0);

		--Savestate, region PCM_REGS. It includes WRA, the eight 27-bit fixed-point
		--read pointers, so each voice resumes mid-sample instead of at its loop point.
		SS_ADDR		: in std_logic_vector(5 downto 0) := (others => '0');
		SS_WR_DATA	: in std_logic_vector(31 downto 0) := (others => '0');
		SS_WR_EN		: in std_logic := '0';
		SS_FREEZE	: in std_logic := '0';
		SS_RD_DATA	: out std_logic_vector(31 downto 0)
	);
end PCM;

architecture rtl of PCM is
	
	type reg8x8_t is array(0 to 7) of std_logic_vector(7 downto 0);
	type reg8x16_t is array(0 to 7) of std_logic_vector(15 downto 0);
	type reg8x27_t is array(0 to 7) of std_logic_vector(26 downto 0);
	
	--IO
	signal OLD_WR_N	: std_logic;
	signal OLD_RD_N 	: std_logic;
	signal WR_F 		: std_logic;
	signal RD_F 		: std_logic;
	signal IO_WR 		: std_logic;
	signal IO_RD 		: std_logic;
	signal RAM_WR 		: std_logic;
	signal RAM_RD 		: std_logic;
	signal RAM_DI 		: std_logic_vector(7 downto 0);
	
	--Registers
	signal WB 			: std_logic_vector(3 downto 0);
	signal CB 			: std_logic_vector(2 downto 0);
	signal ONOFF 		: std_logic;
	signal ENV 			: reg8x8_t;
	signal PAN 			: reg8x8_t;
	signal FD 			: reg8x16_t;
	signal LS 			: reg8x16_t;
	signal ST 			: reg8x8_t;
	signal CHOFF 		: std_logic_vector(7 downto 0);
	
	signal EN 			: std_logic;
	signal CLK_CNT		: unsigned(5 downto 0);
	signal SAMPLE_CE 	: std_logic;
	signal STEP 		: std_logic;
	signal WRA 			: reg8x27_t;
	signal WRA_RD		: reg8x16_t;
	signal CH 			: unsigned(2 downto 0);
	signal LSUM, RSUM : unsigned(16 downto 0);
	signal LOUT, ROUT : signed(15 downto 0);
		
	signal PCM_REF   : integer;
	signal DO_INT    : std_logic_vector(7 downto 0);
	
	impure function CLAMP16(a: unsigned(16 downto 0)) return unsigned is
		variable res: unsigned(15 downto 0); 
	begin
		if a(16 downto 15) = "01" then
			res := x"7FFF";
		elsif a(16 downto 15) = "10" then
			res := x"8000";
		else
			res := a(16) & a(14 downto 0);
		end if;
		return res;
	end function;


begin

	EN <= ENABLE and CLKEN and not SS_FREEZE;

	----------------------------------------------------------------
	-- Savestate read chain
	----------------------------------------------------------------
	SS_RD_DATA <=
		"0000000000" & OLD_RD_N & OLD_WR_N & std_logic_vector(CH) & STEP &
		CHOFF & ONOFF & CB & WB                                       when SS_ADDR = "000000" else
		ENV(3) & ENV(2) & ENV(1) & ENV(0)                             when SS_ADDR = "000001" else
		ENV(7) & ENV(6) & ENV(5) & ENV(4)                             when SS_ADDR = "000010" else
		PAN(3) & PAN(2) & PAN(1) & PAN(0)                             when SS_ADDR = "000011" else
		PAN(7) & PAN(6) & PAN(5) & PAN(4)                             when SS_ADDR = "000100" else
		FD(1) & FD(0)                                                 when SS_ADDR = "000101" else
		FD(3) & FD(2)                                                 when SS_ADDR = "000110" else
		FD(5) & FD(4)                                                 when SS_ADDR = "000111" else
		FD(7) & FD(6)                                                 when SS_ADDR = "001000" else
		LS(1) & LS(0)                                                 when SS_ADDR = "001001" else
		LS(3) & LS(2)                                                 when SS_ADDR = "001010" else
		LS(5) & LS(4)                                                 when SS_ADDR = "001011" else
		LS(7) & LS(6)                                                 when SS_ADDR = "001100" else
		ST(3) & ST(2) & ST(1) & ST(0)                                 when SS_ADDR = "001101" else
		ST(7) & ST(6) & ST(5) & ST(4)                                 when SS_ADDR = "001110" else
		"00000" & WRA(0)   when SS_ADDR = "001111" else
		"00000" & WRA(1)   when SS_ADDR = "010000" else
		"00000" & WRA(2)   when SS_ADDR = "010001" else
		"00000" & WRA(3)   when SS_ADDR = "010010" else
		"00000" & WRA(4)   when SS_ADDR = "010011" else
		"00000" & WRA(5)   when SS_ADDR = "010100" else
		"00000" & WRA(6)   when SS_ADDR = "010101" else
		"00000" & WRA(7)   when SS_ADDR = "010110" else
		std_logic_vector(ROUT) & std_logic_vector(LOUT)               when SS_ADDR = "010111" else
		"000000000000000" & std_logic_vector(LSUM)                    when SS_ADDR = "011000" else
		"000000000000000" & std_logic_vector(RSUM)                    when SS_ADDR = "011001" else
		x"0000" & DO_INT & RAM_DI                                     when SS_ADDR = "011010" else
		(others => '0');
	
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			OLD_WR_N <= '1';
			OLD_RD_N <= '1';
		elsif rising_edge(CLK) then
			if EN = '1' then
				OLD_WR_N <= WR_N;
				OLD_RD_N <= RD_N;
			end if;

			if SS_WR_EN = '1' and SS_ADDR = "000000" then
				OLD_WR_N <= SS_WR_DATA(20);
				OLD_RD_N <= SS_WR_DATA(21);
			end if;
		end if;
	end process;
	
	WR_F <= not WR_N and OLD_WR_N;
	RD_F <= not RD_N and OLD_RD_N;
	
	IO_WR <= '1' when CS_N = '0' and WR_F = '1' and A(12 downto 4) = "000000000" else '0';
	IO_RD <= '1' when CS_N = '0' and RD_F = '1' and A(12 downto 4) = "000000001" else '0';
	RAM_WR <= '1' when CS_N = '0' and WR_F = '1' and A(12) = '1' else '0';
	RAM_RD <= '1' when CS_N = '0' and RD_F = '1' and A(12) = '1' else '0';
	
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			WB <= (others => '0');
			CB <= (others => '0');
			ONOFF <= '0';
			ENV <= (others => (others => '0'));
			PAN <= (others => (others => '1'));
			FD <= (others => (others => '0'));
			LS <= (others => (others => '0'));
			ST <= (others => (others => '0'));
			CHOFF <= (others => '0');
			DO_INT <= (others => '0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				if IO_WR = '1' then
					case A(3 downto 0) is
						when x"0" =>			--ENV
							ENV(to_integer(unsigned(CB))) <= DI;
						when x"1" =>			--PAN
							PAN(to_integer(unsigned(CB))) <= DI;
						when x"2" =>			--FDL
							FD(to_integer(unsigned(CB)))(7 downto 0) <= DI;
						when x"3" =>			--FDH
							FD(to_integer(unsigned(CB)))(15 downto 8) <= DI;
						when x"4" =>			--LSL
							LS(to_integer(unsigned(CB)))(7 downto 0) <= DI;
						when x"5" =>			--LSH
							LS(to_integer(unsigned(CB)))(15 downto 8) <= DI;
						when x"6" =>			--ST
							ST(to_integer(unsigned(CB))) <= DI;
						when x"7" =>			--Control register
							if DI(6) = '0' then
								WB <= DI(3 downto 0);
							else 
								CB <= DI(2 downto 0);
							end if;
							ONOFF <= DI(7);
						when x"8" =>			--Channel ON/OFF
							CHOFF <= DI;
						when others => null;
					end case;
				elsif IO_RD = '1' then
					case A(3 downto 0) is
						when x"0" =>			--
							DO_INT <= WRA_RD(0)(7 downto 0);
						when x"1" =>			--
							DO_INT <= WRA_RD(0)(15 downto 8);
						when x"2" =>			--
							DO_INT <= WRA_RD(1)(7 downto 0);
						when x"3" =>			--
							DO_INT <= WRA_RD(1)(15 downto 8);
						when x"4" =>			--
							DO_INT <= WRA_RD(2)(7 downto 0);
						when x"5" =>			--
							DO_INT <= WRA_RD(2)(15 downto 8);
						when x"6" =>			--
							DO_INT <= WRA_RD(3)(7 downto 0);
						when x"7" =>			--
							DO_INT <= WRA_RD(3)(15 downto 8);
						when x"8" =>			--
							DO_INT <= WRA_RD(4)(7 downto 0);
						when x"9" =>			--
							DO_INT <= WRA_RD(4)(15 downto 8);
						when x"A" =>			--
							DO_INT <= WRA_RD(5)(7 downto 0);
						when x"B" =>			--
							DO_INT <= WRA_RD(5)(15 downto 8);
						when x"C" =>			--
							DO_INT <= WRA_RD(6)(7 downto 0);
						when x"D" =>			--
							DO_INT <= WRA_RD(6)(15 downto 8);
						when x"E" =>			--
							DO_INT <= WRA_RD(7)(7 downto 0);
						when x"F" =>			--
							DO_INT <= WRA_RD(7)(15 downto 8);
						when others => null;
					end case;
				elsif RAM_RD = '1' then
					DO_INT <= RAM_DI_A;
				end if;

			end if;

			--Savestate restore for the register file this process owns.
			if SS_WR_EN = '1' then
				case SS_ADDR is
					when "000000" =>
						WB    <= SS_WR_DATA(3 downto 0);
						CB    <= SS_WR_DATA(6 downto 4);
						ONOFF <= SS_WR_DATA(7);
						CHOFF <= SS_WR_DATA(15 downto 8);
					when "000001" =>
						ENV(0) <= SS_WR_DATA(7 downto 0);   ENV(1) <= SS_WR_DATA(15 downto 8);
						ENV(2) <= SS_WR_DATA(23 downto 16); ENV(3) <= SS_WR_DATA(31 downto 24);
					when "000010" =>
						ENV(4) <= SS_WR_DATA(7 downto 0);   ENV(5) <= SS_WR_DATA(15 downto 8);
						ENV(6) <= SS_WR_DATA(23 downto 16); ENV(7) <= SS_WR_DATA(31 downto 24);
					when "000011" =>
						PAN(0) <= SS_WR_DATA(7 downto 0);   PAN(1) <= SS_WR_DATA(15 downto 8);
						PAN(2) <= SS_WR_DATA(23 downto 16); PAN(3) <= SS_WR_DATA(31 downto 24);
					when "000100" =>
						PAN(4) <= SS_WR_DATA(7 downto 0);   PAN(5) <= SS_WR_DATA(15 downto 8);
						PAN(6) <= SS_WR_DATA(23 downto 16); PAN(7) <= SS_WR_DATA(31 downto 24);
					when "000101" => FD(0) <= SS_WR_DATA(15 downto 0); FD(1) <= SS_WR_DATA(31 downto 16);
					when "000110" => FD(2) <= SS_WR_DATA(15 downto 0); FD(3) <= SS_WR_DATA(31 downto 16);
					when "000111" => FD(4) <= SS_WR_DATA(15 downto 0); FD(5) <= SS_WR_DATA(31 downto 16);
					when "001000" => FD(6) <= SS_WR_DATA(15 downto 0); FD(7) <= SS_WR_DATA(31 downto 16);
					when "001001" => LS(0) <= SS_WR_DATA(15 downto 0); LS(1) <= SS_WR_DATA(31 downto 16);
					when "001010" => LS(2) <= SS_WR_DATA(15 downto 0); LS(3) <= SS_WR_DATA(31 downto 16);
					when "001011" => LS(4) <= SS_WR_DATA(15 downto 0); LS(5) <= SS_WR_DATA(31 downto 16);
					when "001100" => LS(6) <= SS_WR_DATA(15 downto 0); LS(7) <= SS_WR_DATA(31 downto 16);
					when "001101" =>
						ST(0) <= SS_WR_DATA(7 downto 0);   ST(1) <= SS_WR_DATA(15 downto 8);
						ST(2) <= SS_WR_DATA(23 downto 16); ST(3) <= SS_WR_DATA(31 downto 24);
					when "001110" =>
						ST(4) <= SS_WR_DATA(7 downto 0);   ST(5) <= SS_WR_DATA(15 downto 8);
						ST(6) <= SS_WR_DATA(23 downto 16); ST(7) <= SS_WR_DATA(31 downto 24);
					when others => null;
				end case;
			end if;
		end if;
	end process;

	DO <= DO_INT;
	
	RAM_ADDR_A <= WB & A(11 downto 0);
	RAM_DO_A <= DI;
	RAM_WE_A <= RAM_WR;
	
	PCM_REF <= 53203423 when PALSW = '1' else 53693175;

	CEGen : entity work.CEGen
	port map(
		CLK   		=> CLK,
		RST_N       => RST_N,		
		IN_CLK   	=> PCM_REF,
		OUT_CLK   	=> 520832,				--12500000/384=32552*8*2=520832
		CE   			=> SAMPLE_CE
	);
	
	process( RST_N, CLK )
	variable WD : unsigned(7 downto 0);
	variable MUL16 : unsigned(15 downto 0);
	variable MUL19L, MUL19R : unsigned(18 downto 0);
	variable SUM17L, SUM17R : unsigned(16 downto 0);
	begin
		if RST_N = '0' then
			CH <= (others => '0');
			WRA <= (others => (others => '0'));
			WRA_RD <= (others => (others => '0'));
			LOUT <= (others => '0');
			ROUT <= (others => '0');
			LSUM <= (others => '0');
			RSUM <= (others => '0');
			STEP <= '0';
		elsif rising_edge(CLK) then
			RAM_DI <= RAM_DI_B;
			if ENABLE = '1' and SAMPLE_CE = '1' then
				STEP <= not STEP;
				if STEP = '0' then
					if CHOFF(to_integer(CH)) = '1' or ONOFF = '0' then
						WRA(to_integer(CH)) <= ST(to_integer(CH)) & "0000000000000000000";
					elsif RAM_DI = x"FF" then
						WRA(to_integer(CH)) <= LS(to_integer(CH)) & "00000000000";
					end if;
				else
					CH <= CH + 1;
					
					-- The readable address is the one of the sample being played, taken
					-- before the step: it never shows the 0xFF loop mark, and it holds
					-- its last value while the chip is off.
					if ONOFF = '1' then
						WRA_RD(to_integer(CH)) <= WRA(to_integer(CH))(26 downto 11);
					end if;
					
					-- 0xFF is the loop marker, not sample data: the real chip
					-- never plays it (GPGX: "infinite loop should not output
					-- any data"). Without this gate its sign+magnitude decode
					-- is full-scale positive, so a channel whose loop start
					-- also lands in 0xFF-filled RAM (what erased banks hold)
					-- pins the mix at +max — the Sonic CD sound-test
					-- track-switch static.
					if CHOFF(to_integer(CH)) = '0' and ONOFF = '1' and RAM_DI /= x"FF" then
						WD := unsigned(RAM_DI);
					else
						WD := (others => '0');
					end if;
					
					MUL16 := resize( WD(6 downto 0) * unsigned(ENV(to_integer(CH))), MUL16'length );
					MUL19L := resize( MUL16 * unsigned(PAN(to_integer(CH))(3 downto 0)), MUL19L'length );
					MUL19R := resize( MUL16 * unsigned(PAN(to_integer(CH))(7 downto 4)), MUL19R'length );
					
					if WD(7) = '1' then
						SUM17L := resize( LSUM + MUL19L(18 downto 5), SUM17L'length );
						SUM17R := resize( RSUM + MUL19R(18 downto 5), SUM17R'length );
					else
						SUM17L := resize( LSUM - MUL19L(18 downto 5), SUM17L'length );
						SUM17R := resize( RSUM - MUL19R(18 downto 5), SUM17R'length );
					end if;
					
					if CH = 7 then
						LOUT <= signed( CLAMP16(SUM17L) );
						ROUT <= signed( CLAMP16(SUM17R) );
						LSUM <= (others => '0');
						RSUM <= (others => '0');
					else
						LSUM <= SUM17L;
						RSUM <= SUM17R;
					end if;
					
					if CHOFF(to_integer(CH)) = '0' and ONOFF = '1' then
						WRA(to_integer(CH)) <= std_logic_vector( unsigned(WRA(to_integer(CH))) + unsigned(FD(to_integer(CH))) );
					end if;
				end if;
			end if;

			--Savestate restore for the playback engine.
			if SS_WR_EN = '1' then
				case SS_ADDR is
					when "000000" =>
						STEP <= SS_WR_DATA(16);
						CH   <= unsigned(SS_WR_DATA(19 downto 17));
					-- The readable addresses are not in the state: they restart from
					-- the restored pointers and follow them from the next sample on.
					when "001111" => WRA(0) <= SS_WR_DATA(26 downto 0); WRA_RD(0) <= SS_WR_DATA(26 downto 11);
					when "010000" => WRA(1) <= SS_WR_DATA(26 downto 0); WRA_RD(1) <= SS_WR_DATA(26 downto 11);
					when "010001" => WRA(2) <= SS_WR_DATA(26 downto 0); WRA_RD(2) <= SS_WR_DATA(26 downto 11);
					when "010010" => WRA(3) <= SS_WR_DATA(26 downto 0); WRA_RD(3) <= SS_WR_DATA(26 downto 11);
					when "010011" => WRA(4) <= SS_WR_DATA(26 downto 0); WRA_RD(4) <= SS_WR_DATA(26 downto 11);
					when "010100" => WRA(5) <= SS_WR_DATA(26 downto 0); WRA_RD(5) <= SS_WR_DATA(26 downto 11);
					when "010101" => WRA(6) <= SS_WR_DATA(26 downto 0); WRA_RD(6) <= SS_WR_DATA(26 downto 11);
					when "010110" => WRA(7) <= SS_WR_DATA(26 downto 0); WRA_RD(7) <= SS_WR_DATA(26 downto 11);
					when "010111" =>
						LOUT <= signed(SS_WR_DATA(15 downto 0));
						ROUT <= signed(SS_WR_DATA(31 downto 16));
					when "011000" => LSUM <= unsigned(SS_WR_DATA(16 downto 0));
					when "011001" => RSUM <= unsigned(SS_WR_DATA(16 downto 0));
					when "011010" => RAM_DI <= SS_WR_DATA(7 downto 0);
					when others => null;
				end case;
			end if;
		end if;
	end process;
	
	RAM_ADDR_B <= WRA(to_integer(CH))(26 downto 11);

	
	SL <= LOUT;
	SR <= ROUT;

end rtl;