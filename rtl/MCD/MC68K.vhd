library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library STD;
use IEEE.NUMERIC_STD.ALL;

entity M68K_WRAP is
	port(
		CLK			: in std_logic;
		RST_N			: in std_logic;
		
		RESET_I_N	: in std_logic;
		CLKEN_P 		: in std_logic;
		CLKEN_N 		: in std_logic;
		A   			: out std_logic_vector(23 downto 1);
		DI				: in std_logic_vector(15 downto 0);
		DO				: out std_logic_vector(15 downto 0);
		AS_N			: out std_logic;
		RNW			: out std_logic;
		UDS_N			: out std_logic;
		LDS_N			: out std_logic;
		DTACK_N		: in std_logic;
		IPL_N			: in std_logic_vector(2 downto 0);
		VPA_N			: in std_logic;
		FC				: out std_logic_vector(2 downto 0);
		HALT_I_N		: in std_logic;
		BGACK_N		: in std_logic;
		BG_N			: out std_logic;
		BR_N			: in std_logic;
		VMA_N			: out std_logic;
		E				: out std_logic;
		BERR_N		: in std_logic;
		RESET_O_N	: out std_logic;
		HALT_O_N		: out std_logic;

		--Savestate. SS_FREEZE gates the phase enables. SS_FROZEN reports that the
		--gate is engaged.
		SS_FREEZE	: in std_logic := '0';
		SS_FROZEN	: out std_logic;
		SS_ADDR		: in std_logic_vector(7 downto 0) := (others => '0');
		SS_WR_DATA	: in std_logic_vector(15 downto 0) := (others => '0');
		SS_WR_EN		: in std_logic := '0';
		SS_RD_DATA	: out std_logic_vector(15 downto 0)
	);
end M68K_WRAP;

architecture rtl of M68K_WRAP is

	signal extReset		: std_logic;
	signal pwrUp		: std_logic;

	signal AS_N_INT		: std_logic;
	signal BUS_STARTING	: std_logic;
	signal FREEZE_ENG		: std_logic;
	signal LAST_WAS_P		: std_logic;
	signal PULSE			: std_logic;
	signal CLKEN_P_G		: std_logic;
	signal CLKEN_N_G		: std_logic;
	
	COMPONENT fx68k
	PORT
	(
		clk  		: IN  STD_LOGIC;
		extReset : IN  STD_LOGIC;
		pwrUp 	: IN  STD_LOGIC;
		enPhi2 	: IN  STD_LOGIC;
		enPhi1 	: IN  STD_LOGIC;
		eab  		: OUT  STD_LOGIC_VECTOR (23 DOWNTO 1);
		iEdb 		: IN  STD_LOGIC_VECTOR (15 DOWNTO 0);
		oEdb 		: OUT STD_LOGIC_VECTOR (15 DOWNTO 0);
		ASn  		: OUT STD_LOGIC;
		eRWn  	: OUT STD_LOGIC;
		UDSn  	: OUT STD_LOGIC;
		LDSn  	: OUT STD_LOGIC;
		DTACKn 	: IN  STD_LOGIC;
		HALTn 	: IN  STD_LOGIC;
		IPL0n 	: IN  STD_LOGIC;
		IPL1n 	: IN  STD_LOGIC;
		IPL2n 	: IN  STD_LOGIC;
		VPAn 		: IN  STD_LOGIC;
		FC0  		: OUT STD_LOGIC;
		FC1  		: OUT STD_LOGIC;
		FC2  		: OUT STD_LOGIC;
		BERRn 	: IN  STD_LOGIC;
		BRn 		: IN  STD_LOGIC;
		BGACKn 	: IN  STD_LOGIC;
		oRESETn  : OUT STD_LOGIC;
		oHALTEDn : OUT STD_LOGIC;
		E  		: OUT STD_LOGIC;
		VMAn  	: OUT STD_LOGIC;
		BGn  		: OUT STD_LOGIC;
		addrOe_o : OUT STD_LOGIC;
		dataOe_o : OUT STD_LOGIC;
		busStarting_o : OUT STD_LOGIC;
		ss_addr    : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		ss_wr_data : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
		ss_wr_en   : IN  STD_LOGIC;
		ss_rd_data : OUT STD_LOGIC_VECTOR(15 DOWNTO 0)
	);
	END COMPONENT;
	
begin

	pwrUp <= not RST_N;
	extReset <= not RESET_I_N or not RST_N;
	
	--Park at bus idle or reset, excluding a newly starting bus cycle.
	--Masking phase enables holds the complete fx68k microstate.
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			FREEZE_ENG <= '0';
			LAST_WAS_P <= '0';
		elsif rising_edge(CLK) then
			--Decide on pulse-free edges after enPhi2. Every image resumes with
			--enPhi1, preserving strict phase alternation across save and load.
			if SS_FREEZE = '0' and PULSE = '0' and LAST_WAS_P = '0' then
				FREEZE_ENG <= '0';
			elsif SS_FREEZE = '1' and PULSE = '0' and LAST_WAS_P = '0' and
			      ((AS_N_INT = '1' and BUS_STARTING = '0') or extReset = '1') then
				FREEZE_ENG <= '1';
			end if;

			--Phase of the last pulse on the ungated stream, which keeps alternating
			--while the gate is engaged.
			if CLKEN_P = '1' then
				LAST_WAS_P <= '1';
			elsif CLKEN_N = '1' then
				LAST_WAS_P <= '0';
			end if;
		end if;
	end process;

	PULSE <= CLKEN_P or CLKEN_N;

	CLKEN_P_G <= CLKEN_P and not FREEZE_ENG;
	CLKEN_N_G <= CLKEN_N and not FREEZE_ENG;

	SS_FROZEN <= FREEZE_ENG;
	AS_N <= AS_N_INT;

	P68K :  fx68k
	port map(
		clk   		=> CLK,
		pwrUp      	=> pwrUp,
		extReset    => extReset,
		enPhi1   	=> CLKEN_P_G,
		enPhi2  	 	=> CLKEN_N_G,
		
		eab   		=> A,
		iEdb   		=> DI,
		oEdb   		=> DO,
		ASn   		=> AS_N_INT,
		eRWn   		=> RNW,
		UDSn   		=> UDS_N,
		LDSn   		=> LDS_N,
		DTACKn		=> DTACK_N,
		HALTn			=> HALT_I_N,
		IPL0n   		=> IPL_N(0),
		IPL1n   		=> IPL_N(1),
		IPL2n   		=> IPL_N(2),
		VPAn   		=> VPA_N,
		VMAn   		=> VMA_N,
		E   			=> E,
		FC0   		=> FC(0),
		FC1   		=> FC(1),
		FC2   		=> FC(2),
		BERRn   		=> BERR_N,
		BRn   		=> BR_N,
		BGACKn   	=> BGACK_N,
		BGn   		=> BG_N,
		oRESETn   	=> RESET_O_N,
		oHALTEDn   	=> HALT_O_N,
		addrOe_o    => open,
		dataOe_o    => open,
		busStarting_o => BUS_STARTING,
		ss_addr     => SS_ADDR,
		ss_wr_data  => SS_WR_DATA,
		ss_wr_en    => SS_WR_EN,
		ss_rd_data  => SS_RD_DATA
	);
	
end rtl;