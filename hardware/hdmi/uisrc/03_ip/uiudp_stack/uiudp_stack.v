
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2022/12/23
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.1
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
/*******************************uiudp_stackģ*********************
--Ƶuiudp_stackģ
*********************************************************************/

`timescale 1ns / 1ps

module uiudp_stack #
(
parameter               CRC_GEN_EN        = 1'b1,          //CRC32ʹ
parameter               INTER_FRAME_GAP   = 4'd12          //֡
)
(   
input  wire             I_uclk,                 //ûʱ
input  wire             I_reset,                //ϵͳλ
input  wire[47:0]       I_mac_local_addr,       //MACַ
input  wire[15:0]       I_udp_local_port,       //UDP˿
input  wire[31:0]       I_ip_local_addr,        //IPַ

input  wire[15:0]		I_udp_dest_port,        //ĿUDP˿
input  wire[31:0]		I_ip_dest_addr,         //ĿIPַ

output wire             O_W_udp_busy,		    //udpдæ
input  wire             I_W_udp_req,            //udpд
input  wire             I_W_udp_valid,          //udpдЧ
input  wire[7:0]        I_W_udp_data,           //udpд
input  wire[15:0]		I_W_udp_len,            //udpд
			
output wire             O_R_udp_valid,          //udpЧ
output wire [7:0]       O_R_udp_data,           //udp
output wire [15:0]      O_R_udp_len,             //udpݳ
output wire [15:0]      O_R_udp_src_port,       //udpԶ˿ں  

input                   I_gmii_rclk,            //PHY RGMIIӿڽʱ				
input                   I_gmii_rvalid,          //PHY RGMIIӿڽЧ
input [7:0]        		I_gmii_rdata,	        //PHY RGMIIӿڽ

input                   I_gmii_tclk,	        //PHY RGMIIӿڷʱ		
output wire             O_gmii_tvalid,          //PHY RGMIIӿڷЧ
output wire [7:0]       O_gmii_tdata,           //PHY RGMIIӿڷ
		
output wire             O_ip_rerror,            //IPմ
output wire 			O_mac_rerror,   // MACմ,
            output wire [15:0] o_dbg_crc_ok,
            output wire [15:0] o_dbg_crc_bad,
            output wire [15:0] o_dbg_lenbad
);

wire         udp_ip_treq;                       //UDP,UDPûUDPݰ       
wire         udp_ip_tvalid;                     //UDP,UDP㷢͵Ч
wire [7 :0]  udp_ip_tdata;                      //UDP,UDP㷢͵Ч
wire [15:0]  udp_ip_tpkg_len;                   //UDP,UDP㷢͵ĿIPַ
wire         udp_ip_tbusy;                      //ip_sendģ׼ãԽudp_layer
wire         ip_udp_rvalid;                     //յip_layerUDPЧź
wire [7 :0]  ip_udp_rdata;                      //ܵip_layerUDPݰ



//UDPģ
uiudp_layer udp_layer_inst 
(
.I_udp_local_port                   (I_udp_local_port   ),  //UDP˿
.I_udp_dest_port		            (I_udp_dest_port    ),  //UDPĿ˿
.I_udp_reset					    (I_reset            ), 

.I_W_udp_clk                        (I_uclk             ),  //UDPûʱ
.I_W_udp_req			            (I_W_udp_req        ),  //ûUDPӿڷ
.I_W_udp_valid		                (I_W_udp_valid      ),  //ûUDPӿڷЧ 
.I_W_udp_data			            (I_W_udp_data       ),  //ûUDPӿڷ
.I_W_udp_len		                (I_W_udp_len        ),  //ûUDPӿڷݳ
.O_W_udp_busy			            (O_W_udp_busy       ),  //ûUDPӿڣUDP׼

.I_R_udp_clk                        (I_uclk             ),
.O_R_udp_valid		                (O_R_udp_valid      ),  //ûUDPӿڶЧ
.O_R_udp_data			            (O_R_udp_data       ),  //ûUDPӿڶ
.O_R_udp_len		                (O_R_udp_len        ),  //ûUDPӿڶݳ
.O_R_udp_src_port		            (O_R_udp_src_port   ),  //ûUDPӿڶݶ˿

.I_udp_ip_tbusy                     (udp_ip_tbusy       ),  //ip_layer׼ź
.O_udp_ip_treq                      (udp_ip_treq        ),  //UDPip_layer
.O_udp_ip_tvalid                    (udp_ip_tvalid      ),  //UDPЧźŵip
.O_udp_ip_tdata                     (udp_ip_tdata       ),  //UDPЧ
.O_udp_ip_tpkg_len                  (udp_ip_tpkg_len    ),  //UDP

.I_udp_ip_rvalid                    (ip_udp_rvalid      ),  //յip_layerUDPЧź
.I_udp_ip_rdata                     (ip_udp_rdata       )   //ܵip_layerUDPݰ
);

//IP layerź
wire        ip_tbusy;     		        //ip_sendģɹռsend_bufferipķź
wire        ip_treq;			        //ip_sendģ飬IP
wire        ip_tvalid;			        //ip_sendģ飬IPЧź
wire [7 :0]	ip_tdata;			        //ip_sendģ飬IP
wire [31:0] ip_taddr;			        //ip_sendģ飬ĿIPַ

wire         ip_rvalid;	                //յЧIPź
wire [7 :0]	 ip_rdata; 	                //յIP
                                  
uiip_layer ip_layer_inst                //IPģ飬շIPݰ(UDP)	 
(
.I_ip_local_addr                    (I_ip_local_addr    ),    //IPַ
.I_ip_dest_addr		                (I_ip_dest_addr     ),    //ĿIPַ 
.I_ip_reset					        (I_reset            ),    //ϵͳλ
.I_ip_clk				            (I_uclk             ),    //ipûʱ
//ip_receiveģյudpݰ͸udp_layer
.O_ip_udp_rvalid		            (ip_udp_rvalid      ),    //upd_layer,ip_receiveģЧUDPݲ 
.O_ip_udp_rdata			            (ip_udp_rdata	    ),    //upd_layer,ip_receiveģЧUDPݲ
//udpݣudp_layerҪõźţЩźŻṩip_sendģ
.O_ip_udp_tbusy			            (udp_ip_tbusy       ),    //ip_sendģ׼ãԽudp_layer   
.I_ip_udp_treq			            (udp_ip_treq        ),    //UDP,UDPûUDPݰ   
.I_ip_udp_tvalid		            (udp_ip_tvalid      ),    //UDP,UDP㷢͵Ч 
.I_ip_udp_tdata			            (udp_ip_tdata       ),    //UDP,UDP㷢͵Ч 
.I_ip_udp_tdata_len		            (udp_ip_tpkg_len    ),    //UDP,UDP㷢͵ĿIPַ 
//ipip_arp_tx
.I_ip_tbusy		                    (ip_tbusy           ),    //ip_arp_tx׼ãܷUDPICMP
.O_ip_treq			                (ip_treq            ),    //͸ip_arp_txģ,IPݰ
.O_ip_tvalid		                (ip_tvalid          ),    //͸ip_arp_txģ,IPݰЧź
.O_ip_tdata		                    (ip_tdata           ),    //͸ip_arp_txģ,IPݰЧ
.O_ip_taddr			                (ip_taddr           ),    //͸ip_arp_txģ,MACĿĵַ 
//ip_arp_rxģIP
.I_ip_rvalid		                (ip_rvalid          ),    //յIPЧźţip_receive
.I_ip_rdata				            (ip_rdata           ),    //յIPݰЧip_receive
.O_ip_rerror			            (O_ip_rerror        )     //յIPݰ
);
	

//ARPģ


wire        mac_cache_ren;
wire [31:0] mac_cache_rip_addr;
wire [47:0] mac_cache_rdest_addr; 	//ip_sendģ飬ѯcacheеMACַ
wire        mac_cache_rdone;
//ARPź,͸ARPѯMAC

wire        arp_treq_en;		    //͵IP޷MAC cacheҵӦMACҪARPͨIPѰԶMAC 
wire[31:0]	arp_treq_ip_addr;		//ڷIPʱ޷ҵMACͨIPַARPѰԶMAC

wire        arp_tbusy;   		    //Ӧarp_sendģ飬ԷARP 
wire        arp_treq;			    //arp_sendģ飬ҪARP
wire        arp_tvalid;		        //arp_sendģ飬ARP Ӧ(arp reply; 2'b11) ARP(arp request ;2'b01 ip)
wire [7 :0]	arp_tdata;			    //arp_sendģ
wire        arp_ttype;		        //arp_sendģ飬ARP IP 
wire [47:0] arp_tdest_mac_addr;	    //arp_sendģ飬ĿĵַMAC
wire        arp_treply_done;	    //arp_sendģ


wire        arp_rvalid;	        //յЧARPź
wire [7 :0] arp_rdata;	        //յЧARP

uiarp_layer arp_layer_inst
(
.I_mac_local_addr     		        (I_mac_local_addr   ), //MACַ
.I_ip_local_addr      		        (I_ip_local_addr    ), //IPַ

.I_arp_clk							(I_uclk             ),  
.I_arp_reset						(I_reset            ),  
//ip_arp_txڷIPʱѯcacheǷMACַ
.I_arp_treq_en					    (arp_treq_en        ),  //ip_arp_txIPcacheûвѯMAC£ʹARP㷢һARP󣬲ѯԶMAC
.I_arp_tip_addr	                    (arp_treq_ip_addr   ),  //ҪѯIPַ
.I_arp_tbusy				        (arp_tbusy	        ),  //ip_arp_tx׼ARP
.O_arp_treq					        (arp_treq	        ),  //ARP
.O_arp_tvalid				        (arp_tvalid         ),  //ARPЧź
.O_arp_tdata					    (arp_tdata          ),  //ARP
.O_arp_ttype                        (arp_ttype          ),  //ARP
.O_arp_tdest_mac_addr		        (arp_tdest_mac_addr ),  //ARPMACַ(ARPԶӦԶARPӦ𣬶ԻȡMACַ)
.O_arp_reply_done				    (arp_treply_done    ),  //ARPsend_bufferȴԶARPӦ

.I_mac_cache_ren				    (mac_cache_ren      ),  //MAC cacheʹ 
.I_mac_cache_rip_addr				(mac_cache_rip_addr ),  //ͨIPַѯMAC
.O_mac_cache_rdest_addr				(mac_cache_rdest_addr),  //ѯMAC
.O_mac_cache_rdone			        (mac_cache_rdone    ),  //ѯMAC
//յARPݰ
.I_arp_rvalid				        (arp_rvalid         ),  //rbufյ̫ΪIP,Ч
.I_arp_rdata					    (arp_rdata          )   //rbufյ̫ΪIP,

);

//IPARPģ
wire         mac_tvalid;            //MAC
wire [7 :0]  mac_tdata;             //MACЧ
wire [1 :0]  mac_tdata_type;        //MAC
wire [47:0]  mac_tdest_addr;          //MACĿĵַ
wire         mac_tbusy;             //MACģǷڷæ

uiip_arp_tx ip_arp_tx_inst 
(
.I_ip_arp_clk						(I_uclk              ), 
.I_ip_arp_reset						(I_reset             ), 
//ѯMAC cacheź
.O_mac_cache_ren			        (mac_cache_ren       ),  //MAC cacheʹܣѯMAC cache
.O_mac_cache_rip_addr		        (mac_cache_rip_addr  ),  //IPַѯMAC
.I_mac_cache_rdest_addr		        (mac_cache_rdest_addr),  //ѯMACַ
.I_mac_cache_rdone		            (mac_cache_rdone     ),  //MAC cacheѯ 
//ARPź,͸ARPѯMAC
.O_arp_treq_en				        (arp_treq_en         ),  //͵IP޷MACcacheҵӦMACҪARPͨIPѰԶMAC 
.O_arp_treq_ip_addr	                (arp_treq_ip_addr    ),  //ڷIPʱ޷ҵMACͨIPַARPѰԶMAC
.O_arp_tbusy				        (arp_tbusy           ),  //Ӧarp㣬arp_sendģ飬ԷARP 
.I_arp_treq			                (arp_treq            ),  //arp㣬arp_sendģ飬ҪARP
.I_arp_tvalid			            (arp_tvalid          ),  //arp㣬arp_sendģ飬ARP Ӧ(arp reply; 2'b11) ARP(arp request ;2'b01 ip)
.I_arp_tdata				        (arp_tdata           ),  //arp㣬arp_sendģ
.I_arp_tdata_type			        (arp_ttype           ),  //arp㣬arp_sendģ飬ARP IP 
.I_arp_tdest_mac_addr	            (arp_tdest_mac_addr  ),  //arp㣬arp_sendģ飬ĿĵַMAC 
.I_arp_treply_done				    (arp_treply_done     ),  //arp㣬arp_sendģ
//IPź
.O_ip_tbusy				            (ip_tbusy            ),  //ip_sendģ飬֪ͨip_sendģ ip_arp_txģԷip
.I_ip_treq			                (ip_treq             ),  //ip㣬ipź
.I_ip_tvalid			            (ip_tvalid           ),  //ip㣬ipЧź
.I_ip_tdata					        (ip_tdata            ),  //ip㣬ipݰ
.I_ip_tdest_addr			        (ip_taddr            ),  //ip㣬Ŀĵַ
//͸MACź
.I_mac_tbusy				        (mac_tbusy           ),  //MAC㣬MACæ
.O_mac_tvalid			            (mac_tvalid          ),  //mac,IPARPЧź
.O_mac_tdata					    (mac_tdata           ),  //mac,IPARP
.O_mac_tdata_type				    (mac_tdata_type      ),  //mac,ݰΪIPARP
.O_mac_tdest_addr		            (mac_tdest_addr       )   //mac,MACĿĵַ

);

//IPARPģ
wire         mac_rvalid;       //MACЧź
wire [7 :0]  mac_rdata;        //MAC
wire [15:0]  mac_rdata_type;   //MACյݰ
wire         mac_rdata_error;  //MAC֡

uiip_arp_rx ip_arp_rx_inst 
(
.I_ip_arp_reset						(I_reset            ), //λ
.I_ip_arp_rclk					    (I_uclk             ), //RX ʱ
.O_ip_rvalid		                (ip_rvalid          ), //յЧIPź
.O_ip_rdata				            (ip_rdata           ), //յIP
.O_arp_rvalid		                (arp_rvalid         ), //յЧARPź 
.O_arp_rdata				        (arp_rdata          ), //յЧARP
.I_mac_rvalid		                (mac_rvalid         ), //MACյЧź
.I_mac_rdata				        (mac_rdata          ), //MACյЧ
.I_mac_rdata_type			        (mac_rdata_type     )  //MACյ֡
);	

//MA
uimac_layer #
(
.CRC_GEN_EN        		            (CRC_GEN_EN         ),  //CRCʹ
.INTER_FRAME_GAP  		            (INTER_FRAME_GAP    )   //֡
)
mac_layer_inst 
(		
.I_mac_local_addr    	            (I_mac_local_addr   ),  //MACַ
.I_mac_reset                        (I_reset            ),	
//յMACݸϲЭ
.I_mac_rclk                         (I_uclk),               //MACЧʱ
.O_mac_rvalid                       (mac_rvalid         ),  //ip_arp_layer,MACЧź
.O_mac_rdata                        (mac_rdata          ),  //ip_arp_layer,MAC
.O_mac_rdata_type                   (mac_rdata_type     ),  //ip_arp_layer,MACյݰ
.O_mac_rdata_error                  (O_mac_rerror        ),  //ip_arp_layer,MAC֡
.o_dbg_crc_ok(o_dbg_crc_ok),
.o_dbg_crc_bad(o_dbg_crc_bad),
.o_dbg_lenbad(o_dbg_lenbad),
//ϲЭݸMAC
.I_mac_tclk                         (I_uclk              ), //MACʱ
.I_mac_tvalid                       (mac_tvalid         ),  //MAC
.I_mac_tdata                        (mac_tdata          ),  //MACЧ
.I_mac_tdata_type                   (mac_tdata_type     ),  //MAC
.I_mac_tdest_addr                   (mac_tdest_addr      ),  //MACĿĵַ
.O_mac_tbusy                        (mac_tbusy          ),  //MACģǷڷæ
//RGMIIתGMIIģ
.I_gmii_rclk                        (I_gmii_rclk        ),  //RGMII ʱ 
.I_gmii_rvalid                      (I_gmii_rvalid      ),  //RGMIIЧź 
.I_gmii_rdata                       (I_gmii_rdata       ),	//RGMIIЧ
//RGMIIתGMIIģ
.I_gmii_tclk                        (I_gmii_tclk        ),  //GMII ʱ
.O_gmii_tvalid                      (O_gmii_tvalid      ),  // RGMII ģ
.O_gmii_tdata                       (O_gmii_tdata       )   // RGMII ģ
		
);
	 

endmodule