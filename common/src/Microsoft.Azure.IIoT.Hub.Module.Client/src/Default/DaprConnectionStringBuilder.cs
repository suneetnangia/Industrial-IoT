namespace Microsoft.Azure.IIoT.Hub.Module.Client.Default {
    using System;
    using System.Collections.Generic;
    using System.Text;

    /// <summary>
    /// 
    /// </summary>
    public class DaprConnectionStringBuilder {
        /// <summary>
        /// 
        /// </summary>
        public string Test { get; private set; }

        /// <summary>
        /// 
        /// </summary>
        /// <param name="daprConnectionString"></param>
        /// <returns></returns>
        public static DaprConnectionStringBuilder Create(string daprConnectionString) {
            return new DaprConnectionStringBuilder {
                Test = "test"
            };
        }
    }
}
